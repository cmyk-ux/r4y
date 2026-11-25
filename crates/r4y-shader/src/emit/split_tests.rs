//! Hardware checks for wave64 compute shaders split across wave32 hosts.
//!
//! The kernel swaps 16-lane rows with ds_swizzle and then mirrors each
//! 16-lane DPP row. Both operations stay within the console's 32-lane halves;
//! lane t must therefore store t ^ 31 on both native wave64 and split wave32
//! adapters.

use super::host::{Dispatch, Host, Root, View};
use super::{Container, Target, emit_for};
use crate::native::{ComputeIo, HwStage, NativeProgram, RootParam, RootType, StageIo};
use crate::{io, ir, resource, structure};
use windows::Win32::Graphics::Direct3D12::*;

const END: u32 = 0xBF81_0000;

const IN_HALF: &[u32] = &[
    0xD8D4_401F,
    0x0100_0000, // ds_swizzle_b32 v1, v0: xor 16
    0x7E04_02FA,
    0xFF01_4001, // v_mov_b32_dpp v2, v1: row mirror
];

fn target(device: &windows::Win32::Graphics::Direct3D12::ID3D12Device) -> Option<Target> {
    let mut options = D3D12_FEATURE_DATA_D3D12_OPTIONS1::default();
    // SAFETY: D3D12 fills the correctly sized OPTIONS1 structure.
    unsafe {
        device
            .CheckFeatureSupport(
                D3D12_FEATURE_D3D12_OPTIONS1,
                (&raw mut options).cast(),
                size_of_val(&options) as u32,
            )
            .ok()?;
    }
    (options.WaveOps.as_bool()
        && options.WaveLaneCountMin > 0
        && options.WaveLaneCountMin <= options.WaveLaneCountMax)
        .then_some(Target {
            lanes_min: options.WaveLaneCountMin,
            lanes_max: options.WaveLaneCountMax,
        })
}

fn program(body: &[u32], threads: u32) -> NativeProgram {
    let mut words = vec![
        0xBE82_0300, // s_mov_b32 s2, s0
        0xBE83_0380, // s_mov_b32 s3, 0
        0xF408_0101,
        0xFA00_0000, // s_load_dwordx4 s[4:7], s[2:3], null
        0x9308_FF01,
        threads * 4, // s_mul_i32 s8, s1, threads * 4
        0xBF8C_C07F, // s_waitcnt lgkmcnt(0)
    ];
    words.extend_from_slice(body);
    words.extend_from_slice(&[
        0x3406_0082, // v_lshlrev_b32 v3, 2, v0
        0x4A06_0608, // v_add_nc_u32 v3, s8, v3
        0xE070_1000,
        0x8001_0203, // buffer_store_dword v2, v3, s[4:7], 0 offen
        END,
    ]);
    NativeProgram {
        stage: HwStage::Cs,
        wave64: true,
        vgprs: 8,
        layout: vec![RootParam {
            root: RootType::Table,
            table_offset_dwords: 0,
            sgprs: 1,
            base_register: 0,
            user_data: 0,
            slot: 0,
        }],
        used: vec![],
        io: StageIo::Cs(ComputeIo {
            rsrc2: 1 << 1 | 1 << 7,
            threads: [threads, 1, 1],
        }),
        code: words.iter().flat_map(|word| word.to_le_bytes()).collect(),
    }
}

fn translate(native: &NativeProgram, target: Target) -> Result<super::HostShader, String> {
    let bytes = crate::dxbc::build(&[]);
    let container = Container::parse(&bytes).map_err(|e| e.to_string())?;
    let p = ir::build(&native.patched_code(), native.wave64, native.vgprs)
        .map_err(|e| e.to_string())?;
    let st = structure::structure(&p).map_err(|e| e.to_string())?;
    let resources = resource::track(&p, &native.layout, native.stage, Some(&st))
        .map_err(|e| e.to_string())?;
    let raised = io::raise(&p, native).map_err(|e| e.to_string())?;
    emit_for(&container, native, &p, &st, &raised, &resources, target)
        .map_err(|e| e.to_string())
}

fn wave_size(dxil: &[u8]) -> Option<u32> {
    let container = Container::parse(dxil).ok()?;
    let psv = container.part(crate::dxbc::FourCC::PSV0)?.data;
    let min = crate::dxbc::u32_at(psv, 4 + 16).ok()?;
    let max = crate::dxbc::u32_at(psv, 4 + 20).ok()?;
    (min == max).then_some(min)
}

fn run(
    host: &Host,
    target: Target,
    native: &NativeProgram,
    groups: u32,
) -> Result<Vec<u32>, String> {
    let cs = translate(native, target)?;
    let (root, pso) = host.compute_pipeline(&cs)?;
    let data = vec![0; (cs.user_data_dwords().max(1)) as usize];
    let StageIo::Cs(io) = &native.io else {
        unreachable!()
    };
    let n = io.threads.iter().product::<u32>() * groups;
    let views = [View::RawUav(n)];
    let out = host.dispatch(
        &root,
        &pso,
        &Dispatch {
            roots: vec![(0, Root::Constants(data))],
            views: &views,
            samplers: &[],
            groups: [groups, 1, 1],
        },
    )?;
    Ok(out.into_iter().next().unwrap_or_default())
}

#[test]
fn in_half_lane_reads_match_console_on_d3d12_hardware() {
    let Ok(host) = Host::new(false) else {
        eprintln!("no D3D12 shader-model 6.6 device; skipped");
        return;
    };
    let Some(target) = target(&host.device) else {
        eprintln!("D3D12 OPTIONS1 wave capabilities unavailable; skipped");
        return;
    };
    if !target.runs(32) && !target.runs(64) {
        eprintln!("adapter supports neither 32- nor 64-lane waves; skipped");
        return;
    }

    for threads in [64, 128, 32] {
        let native = program(IN_HALF, threads);
        let shader = translate(&native, target)
            .unwrap_or_else(|error| panic!("translation for {threads} threads: {error}"));
        let split = !target.runs(64);
        assert_eq!(
            wave_size(&shader.dxil),
            Some(if split { 32 } else { 64 }),
            "the DXIL wave-size declaration for {threads} threads"
        );

        let groups = 3;
        let out = run(&host, target, &native, groups)
            .unwrap_or_else(|error| panic!("dispatch for {threads} threads: {error}"));
        let want: Vec<u32> = (0..groups)
            .flat_map(|_| (0..threads).map(|lane| lane ^ 31))
            .collect();
        assert_eq!(
            out, want,
            "{threads} threads per group (split wave64: {split})"
        );
        eprintln!(
            "{threads} threads per group matched console lane order (split wave64: {split})"
        );
    }
}
