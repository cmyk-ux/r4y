//! Hardware checks for wave64 compute shaders split across wave32 hosts.
//!
//! The kernel swaps 16-lane rows with ds_swizzle and then mirrors each
//! 16-lane DPP row. Both operations stay within the console's 32-lane halves;
//! lane t must therefore store t ^ 31 on both native wave64 and split wave32
//! adapters.

use std::mem::size_of_val;

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

const DPP_ROW_MASK: &[u32] = &[
    0x7E04_0281, // v_mov_b32 v2, 1: disabled rows must preserve this value
    0x7E04_02FA, // first dword of the VOP_DPP instruction below
    0x3F00_E400, // v_mov_b32_dpp v2, v0: quad permute, row_mask 0x3
];

const MASK_COUNT: &[u32] = &[
    0x7D88_00A8, // v_cmp_gt_u32 vcc, 40, v0
    0xBE89_106A, // s_bcnt1_i32_b64 s9, vcc
    0x7E04_0209, // v_mov_b32 v2, s9
];

const MBCNT_LOW: &[u32] = &[
    0xD765_0001,
    0x0001_00C1, // v_mbcnt_lo_u32_b32 v1, -1, 0
    0x7E04_0301, // v_mov_b32 v2, v1 (VGPR source 0x101, not SGPR s1)
];

const CROSS_HALF_READ: &[u32] = &[
    0xD760_0009,
    0x0001_5100, // v_readlane_b32 s9, v0, 40
    0x7E04_0209, // v_mov_b32 v2, s9
];

const CROSS_HALF_WRITE: &[u32] = &[
    0x7E0A_0280, // v_mov_b32 v5, 0
    0xBE89_03AA, // s_mov_b32 s9, 42
    0xD761_0005,
    0x0001_5009, // v_writelane_b32 v5, s9, 40
    0x7E04_0305, // v_mov_b32 v2, v5 (VGPR source 0x105, not SGPR s5)
];

const BRANCH_EXCHANGE: &[u32] = &[
    0x7E04_0281, // v_mov_b32 v2, 1
    0x7D88_0094, // v_cmp_gt_u32 vcc, 20, v0
    0xBE8A_246A, // s_and_saveexec_b64 s[10:11], vcc
    0xBF88_0003, // s_cbranch_execz end
    0xD760_0009,
    0x0001_1500, // v_readlane_b32 s9, v0, 10
    0x7E04_0209, // v_mov_b32 v2, s9
    0x88FE_0A7E, // s_or_b64 exec, exec, s[10:11]
];

const READ_FIRST_LANE: &[u32] = &[
    0x7E12_0500, // v_readfirstlane_b32 s9, v0
    0x7E04_0209, // v_mov_b32 v2, s9
];

const SAVEEXEC_SCC: &[u32] = &[
    0xBE89_03AA, // s_mov_b32 s9, 42
    0x7D88_0080, // v_cmp_gt_u32 vcc, 0, v0 (false in every lane)
    0xBE8C_246A, // s_and_saveexec_b64 s[12:13], vcc
    0xBF84_0003, // s_cbranch_scc0 skip body
    0xD760_000E,
    0x0001_1500, // v_readlane_b32 s14, v0, 10
    0xBE89_03BC, // s_mov_b32 s9, 60 (must not run)
    0x88FE_0C7E, // s_or_b64 exec, exec, s[12:13]
    0x7E04_0209, // v_mov_b32 v2, s9
];

const CONSOLE_LOOP: &[u32] = &[
    0xBE89_0380, // s_mov_b32 s9, 0
    0x7E04_0280, // v_mov_b32 v2, 0
    0x7D8A_0080, // v_cmp_ne_u32 vcc, 0, v0
    0xBE8A_246A, // s_and_saveexec_b64 s[10:11], vcc
    0xBF88_0006, // s_cbranch_execz end
    // loop: each lane t runs t iterations and reads lane 40 each time
    0xD760_0009,
    0x0001_5100, // v_readlane_b32 s9, v0, 40
    0x4A04_0481, // v_add_nc_u32 v2, 1, v2
    0x7D82_0102, // v_cmp_lt_u32 vcc, v2, v0
    0x87FE_6A7E, // s_and_b64 exec, exec, vcc
    0xBF89_FFFA, // s_cbranch_execnz loop
    // end:
    0x88FE_0A7E, // s_or_b64 exec, exec, s[10:11]
    0x4A04_0409, // v_add_nc_u32 v2, s9, v2
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
    let views = [View::RawUav(n), View::Pair];
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
fn wave64_split_matches_console_on_d3d12_hardware() {
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

    // DPP row masks name the four rows of a 64-lane console wave. The
    // upper half maps to rows 2/3 even though it is host rows 0/1.
    for threads in [64, 128] {
        let native = program(DPP_ROW_MASK, threads);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("DPP row-mask dispatch: {error}"));
        let want: Vec<u32> = (0..2)
            .flat_map(|_| {
                (0..threads).map(|lane| {
                    let console_lane = lane % 64;
                    // The mask repeats for each console Wave64, but v0
                    // remains the flat GroupThreadID (0..threads), not the
                    // lane number within that wave.
                    if console_lane < 32 { lane } else { 1 }
                })
            })
            .collect();
        assert_eq!(out, want, "DPP row masks for {threads} threads");
    }

    // Only the Wave32 split needs console-flow lowering. Native Wave64
    // adapters keep their original per-lane path.
    if !target.runs(64) {
        for threads in [64, 48, 32] {
            let native = program(MASK_COUNT, threads);
            let out = run(&host, target, &native, 2)
                .unwrap_or_else(|error| panic!("mask ballot ({threads}): {error}"));
            let count = threads.min(40);
            let want: Vec<u32> = vec![count; (threads * 2) as usize];
            assert_eq!(out, want, "whole-wave mask count for {threads} threads");
        }

        let native = program(MBCNT_LOW, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("console v_mbcnt lane index: {error}"));
        let want: Vec<u32> = (0..2)
            .flat_map(|_| (0..64).map(|lane| lane.min(32)))
            .collect();
        assert_eq!(out, want, "v_mbcnt must count the low console mask across both halves");

        let native = program(CROSS_HALF_READ, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("cross-half v_readlane: {error}"));
        assert_eq!(out, vec![40; 128], "v_readlane must reach lane 40");

        let native = program(CROSS_HALF_WRITE, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("cross-half v_writelane: {error}"));
        let want: Vec<u32> = (0..2)
            .flat_map(|_| (0..64).map(|lane| if lane == 40 { 42 } else { 0 }))
            .collect();
        assert_eq!(out, want, "v_writelane must address console lane 40");

        let native = program(BRANCH_EXCHANGE, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("branch with one half inactive: {error}"));
        let want: Vec<u32> = (0..2)
            .flat_map(|_| (0..64).map(|lane| if lane < 20 { 10 } else { 1 }))
            .collect();
        assert_eq!(out, want, "exchange inside a uniform console-flow branch");

        let native = program(READ_FIRST_LANE, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("cross-half readfirstlane: {error}"));
        assert_eq!(out, vec![0; 128], "readfirstlane must select console lane zero");

        let native = program(SAVEEXEC_SCC, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("saveexec SCC branch: {error}"));
        assert_eq!(out, vec![42; 128], "SCC must test the new EXEC mask");

        let native = program(CONSOLE_LOOP, 64);
        let out = run(&host, target, &native, 2)
            .unwrap_or_else(|error| panic!("cross-half readlane in divergent loop: {error}"));
        let want: Vec<u32> = (0..2)
            .flat_map(|_| (0..64).map(|lane| lane + 40))
            .collect();
        assert_eq!(
            out, want,
            "each lane must finish its own iteration count while the full console wave reads lane 40"
        );
    }
}
