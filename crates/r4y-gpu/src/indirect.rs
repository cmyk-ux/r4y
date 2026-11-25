//! Indirect execution's arguments, bounded before the GPU reads them. The
//! title's own compute passes write most of them; a pass we drop or
//! translate wrongly leaves whatever the memory held, and a draw of four
//! billion vertices or a dispatch past the host's limits runs until the
//! host resets the display driver. So every record is clamped on the GPU,
//! just before its execution, by a compute shader of ours (HLSL compiled by
//! the system's compiler; a 5.1 shader with its root signature inside).
//!
//! Each list also has a budget (2^27 vertex instances or threads, groups
//! counted as 64 threads, mesh groups as 128): records past it run empty,
//! so a list of thousands of garbage records cannot run for seconds
//! either.
//!
//! shortcut: the bounds (2^24 vertices, 2^26 vertex instances, 65,535
//! groups per dimension and 2^20 per dispatch, one-dimensional mesh
//! dispatches, the budget) cut legitimate work beyond them; raise them if
//! the title needs more.

use windows::Win32::Graphics::Direct3D::Fxc::D3DCompile;
use windows::Win32::Graphics::Direct3D::ID3DBlob;
use windows::Win32::Graphics::Direct3D12::*;
use std::sync::Arc;

use windows::core::s;

use crate::host::{HostList, host};
use crate::shadow::Shadow;

const SOURCE: &str = r#"
#define RS "RootConstants(num32BitConstants=4, b0), SRV(t0), SRV(t1), UAV(u0), UAV(u1)"
cbuffer Record : register(b0) { uint kind; uint stride; uint records; uint has_count; };
ByteAddressBuffer args : register(t0);
ByteAddressBuffer count_buf : register(t1);
RWByteAddressBuffer dst_args : register(u0);
// The list's work so far (vertex instances, threads): past the budget,
// records run empty.
RWByteAddressBuffer budget : register(u1);
static const uint BUDGET = 1u << 27;
// Groups of one dispatch; more run empty.
static const uint GROUPS = 1u << 20;

// Bounded, saturating accounting: never wrap the per-list budget and never
// spin indefinitely under contention.
bool charge_budget(uint cost) {
    if (cost == 0) return false;
    uint before;
    budget.InterlockedOr(0, 0, before);
    bool settled = false;
    [allow_uav_condition]
    for (uint tries = 0; tries < 256 && before < BUDGET; tries++) {
        uint next = (BUDGET - before <= cost) ? BUDGET : (before + cost);
        uint previous;
        budget.InterlockedCompareExchange(0, before, next, previous);
        if (previous == before) { settled = true; break; }
        before = previous;
    }
    return !settled || before >= BUDGET || BUDGET - before < cost;
}

[RootSignature(RS)]
[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
    // ExecuteIndirect also honors this count. The helper must honor it too:
    // records beyond the active count are not read or copied.
    uint active = records;
    if (has_count != 0) active = min(active, count_buf.Load(0));
    if (id.x >= active) return;

    uint at = id.x * stride;
    uint cost;
    if (kind <= 1) {
        // Draws: vertex or index count, then instances.
        uint count = min(args.Load(at), 1u << 24);
        uint instances = min(args.Load(at + 4), (1u << 26) / max(count, 1u));
        cost = count * instances;
        for (uint off = 8; off < stride; off += 4) {
            dst_args.Store(at + off, args.Load(at + off));
        }
        bool over = charge_budget(cost);
        if (over) {
            count = 0;
            instances = 0;
        }
        dst_args.Store2(at, uint2(count, instances));
    } else if (kind == 2) {
        uint3 g = min(args.Load3(at), uint3(65535u, 65535u, 65535u));
        // x * y fits 32 bits; the whole count may not.
        if (g.z != 0 && g.x * g.y > GROUPS / g.z) {
            g = uint3(0, 0, 0);
        }
        cost = g.x * g.y * g.z * 64u;
        for (uint off = 12; off < stride; off += 4) {
            dst_args.Store(at + off, args.Load(at + off));
        }
        if (charge_budget(cost)) g = uint3(0, 0, 0);
        dst_args.Store3(at, g);
    } else {
        // Mesh dispatches: the console's are one-dimensional.
        uint3 g = args.Load3(at);
        g = uint3(min(g.x, 65535u), min(g.y, 1u), min(g.z, 1u));
        cost = g.x * g.y * g.z * 128u;
        for (uint off = 12; off < stride; off += 4) {
            dst_args.Store(at + off, args.Load(at + off));
        }
        if (charge_budget(cost)) g = uint3(0, 0, 0);
        dst_args.Store3(at, g);
    }
}
"#;

struct Clamp {
    root: ID3D12RootSignature,
    pso: ID3D12PipelineState,
}

// SAFETY: D3D12 objects are free-threaded.
unsafe impl Send for Clamp {}
// SAFETY: as above.
unsafe impl Sync for Clamp {}

fn clamp() -> Option<&'static Clamp> {
    static CLAMP: std::sync::OnceLock<Option<Clamp>> = std::sync::OnceLock::new();
    CLAMP
        .get_or_init(|| match make() {
            Ok(c) => Some(c),
            Err(e) => {
                tracing::warn!(error = %e, "no argument clamp: indirect execution dropped");
                None
            }
        })
        .as_ref()
}

fn compile_clamp() -> windows::core::Result<ID3DBlob> {
    let mut code: Option<ID3DBlob> = None;
    let mut errors: Option<ID3DBlob> = None;
    // SAFETY: the HLSL source and entry-point names live through the call;
    // both output pointers refer to our local Options.
    let compiled = unsafe {
        D3DCompile(
            SOURCE.as_ptr().cast(),
            SOURCE.len(),
            s!("clamp"),
            None,
            None,
            s!("main"),
            s!("cs_5_1"),
            0,
            0,
            &mut code,
            Some(&mut errors),
        )
    };
    if let Err(error) = compiled {
        if let Some(errors) = errors {
            // SAFETY: the blob owns the diagnostic bytes being read.
            let text = unsafe {
                std::slice::from_raw_parts(
                    errors.GetBufferPointer().cast::<u8>(),
                    errors.GetBufferSize(),
                )
            };
            tracing::warn!("argument clamp: {}", String::from_utf8_lossy(text));
        }
        return Err(error);
    }
    code.ok_or_else(windows::core::Error::empty)
}

fn make_for(device: &ID3D12Device) -> windows::core::Result<Clamp> {
    let code = compile_clamp()?;
    // SAFETY: the blob's own bytes; the root signature is inside the shader.
    unsafe {
        let bytes = std::slice::from_raw_parts(
            code.GetBufferPointer().cast::<u8>(),
            code.GetBufferSize(),
        );
        let root: ID3D12RootSignature = device.CreateRootSignature(0, bytes)?;
        let pso = device.CreateComputePipelineState(&D3D12_COMPUTE_PIPELINE_STATE_DESC {
            pRootSignature: std::mem::transmute_copy(&root),
            CS: D3D12_SHADER_BYTECODE {
                pShaderBytecode: bytes.as_ptr().cast(),
                BytecodeLength: bytes.len(),
            },
            ..Default::default()
        })?;
        Ok(Clamp { root, pso })
    }
}

fn make() -> windows::core::Result<Clamp> {
    let device = &host().ok_or_else(windows::core::Error::empty)?.device;
    make_for(device)
}

/// Minimum record byte stride for a supported PC indirect argument kind.
fn min_stride(kind: u32) -> Option<u32> {
    match kind {
        0 => Some(16),
        1 => Some(20),
        2 | 10 => Some(12),
        _ => None,
    }
}

/// Validates the byte range and the dword alignment required by ByteAddressBuffer.
fn validate_layout(
    (kind, stride, records): (u32, u32, u32),
    args_gpu: u64,
    count_gpu: Option<u64>,
) -> Option<u64> {
    if stride < min_stride(kind)? || !stride.is_multiple_of(4) || !args_gpu.is_multiple_of(4) {
        return None;
    }
    if count_gpu.is_some_and(|address| !address.is_multiple_of(4)) {
        return None;
    }
    let bytes = u64::from(stride).checked_mul(u64::from(records))?;
    (bytes <= u64::from(u32::MAX)).then_some(bytes)
}

/// Records one non-destructive clamp dispatch against raw GPU virtual
/// addresses. Resource state transitions and lifetime are the caller's job.
fn record_clamp(
    c: &Clamp,
    l: &ID3D12GraphicsCommandList,
    dst: &ID3D12Resource,
    budget: u64,
    args_gpu: u64,
    count_gpu: Option<u64>,
    (kind, stride, records): (u32, u32, u32),
) -> bool {
    if validate_layout((kind, stride, records), args_gpu, count_gpu).is_none() {
        return false;
    }
    // SAFETY: live D3D12 buffer resources.
    let dst_gpu = unsafe { dst.GetGPUVirtualAddress() };
    if !budget.is_multiple_of(4) || !dst_gpu.is_multiple_of(4) {
        return false;
    }
    let constants = [kind, stride, records, u32::from(count_gpu.is_some())];
    // SAFETY: an open list, a compatible root signature/pipeline, and live
    // source, optional count, destination and budget buffer GPU addresses.
    unsafe {
        l.ResourceBarrier(&[uav_barrier()]);
        l.SetComputeRootSignature(&c.root);
        l.SetPipelineState(&c.pso);
        l.SetComputeRoot32BitConstants(0, 4, constants.as_ptr().cast(), 0);
        l.SetComputeRootShaderResourceView(1, args_gpu);
        l.SetComputeRootShaderResourceView(2, count_gpu.unwrap_or(args_gpu));
        l.SetComputeRootUnorderedAccessView(3, dst_gpu);
        l.SetComputeRootUnorderedAccessView(4, budget);
        if records > 0 {
            l.Dispatch(records.div_ceil(64), 1, 1);
        }
    }
    true
}

/// Records a non-destructive clamp of active indirect records into this
/// list's reusable device-local scratch buffer. The title's argument and
/// optional count buffers are read-only inputs; ExecuteIndirect consumes
/// the returned output buffer at offset zero.
pub(crate) fn bound(
    list: &HostList,
    shadow: &Arc<Shadow>,
    gpu: u64,
    count: Option<(&Arc<Shadow>, u64)>,
    (kind, stride, records): (u32, u32, u32),
) -> Option<ID3D12Resource> {
    let count_gpu = count.map(|(counter, address)| counter.gpu(address));
    let bytes = validate_layout((kind, stride, records), gpu, count_gpu)?;
    let c = clamp()?;
    let budget = list.budget()?;
    let dst = list.indirect_scratch(bytes)?;

    // The source and count are shader reads. If they alias the same shadow
    // resource, the tracker coalesces these compatible read states.
    list.buffer_state(shadow, crate::host::BUFFER_SHADER_RESOURCE);
    if let Some((counter, _)) = count {
        list.buffer_state(counter, crate::host::BUFFER_SHADER_RESOURCE);
    }
    if !record_clamp(
        c,
        &list.list,
        &dst,
        budget,
        gpu,
        count_gpu,
        (kind, stride, records),
    ) {
        return None;
    }
    list.indirect_ready();
    Some(dst)
}
fn uav_barrier() -> D3D12_RESOURCE_BARRIER {
    D3D12_RESOURCE_BARRIER {
        Type: D3D12_RESOURCE_BARRIER_TYPE_UAV,
        Flags: D3D12_RESOURCE_BARRIER_FLAG_NONE,
        Anonymous: D3D12_RESOURCE_BARRIER_0 {
            UAV: std::mem::ManuallyDrop::new(D3D12_RESOURCE_UAV_BARRIER { pResource: std::mem::ManuallyDrop::new(None) }),
        },
    }
}

#[cfg(test)]
mod tests {
    /// HLSL syntax and the embedded root signature compile without a GPU.
    #[test]
    fn argument_clamp_hlsl_compiles_without_a_gpu() {
        assert!(super::compile_clamp().is_ok());
    }

    /// The host also accepts the compiled root signature and compute PSO.
    #[test]
    fn argument_clamp_builds_on_host() {
        let Some(host) = crate::host::host() else {
            return; // No usable D3D12 host adapter on this machine.
        };
        assert!(super::make_for(&host.device).is_ok());
    }

    #[test]
    fn clamp_limits_its_work_to_execute_indirect_count() {
        assert!(super::SOURCE.contains("active = min(active, count_buf.Load(0))"));
        assert!(super::SOURCE.contains("if (id.x >= active) return"));
        assert!(super::SOURCE.contains("ByteAddressBuffer args : register(t0)"));
        assert!(super::SOURCE.contains("RWByteAddressBuffer dst_args : register(u0)"));
        assert!(!super::SOURCE.contains("args.Store"));
        assert!(super::SOURCE.contains("dst_args.Store"));
    }

    #[test]
    fn clamp_without_count_keeps_the_maximum_record_count() {
        // has_count == 0 leaves the active range equal to `records`.
        assert!(super::SOURCE.contains("uint active = records"));
    }

    #[test]
    fn indirect_layout_rejects_short_or_unaligned_records() {
        assert_eq!(super::min_stride(0), Some(16));
        assert_eq!(super::min_stride(1), Some(20));
        assert_eq!(super::min_stride(2), Some(12));
        assert_eq!(super::min_stride(10), Some(12));
        assert_eq!(super::min_stride(99), None);
        assert_eq!(super::validate_layout((0, 12, 2), 0x1000, None), None);
        assert_eq!(super::validate_layout((0, 16, 2), 0x1002, None), None);
        assert_eq!(super::validate_layout((0, 16, 2), 0x1000, Some(0x2002)), None);
    }

    #[test]
    fn indirect_layout_checks_scratch_size() {
        assert_eq!(super::validate_layout((0, 16, 4), 0x1000, None), Some(64));
        assert_eq!(super::validate_layout((2, 12, 0), 0x1000, None), Some(0));
    }

    #[test]
    fn count_limits_clamp_writes_on_host() {
        use windows::Win32::Graphics::Direct3D12::*;
        use windows::Win32::Graphics::Dxgi::Common::DXGI_SAMPLE_DESC;

        let Some(host) = crate::host::host() else {
            return; // No usable D3D12 host adapter on this machine.
        };
        let bytes = 3 * 16u64;
        const SENTINEL: u32 = 0xDEAD_BEEF;
        let source_words = [
            0x11u32, 0x2, 0x3, 0x4,
            0x20, 0x30, 0x40, 0x50,
            0x60, 0x70, 0x80, 0x90,
        ];
        let (source, source_data) = host.shared_buffer(bytes).unwrap();
        let (count, count_data) = host.shared_buffer(256).unwrap();
        // SAFETY: these are the mapped pointers returned by shared_buffer.
        unsafe {
            std::ptr::copy_nonoverlapping(source_words.as_ptr(), source_data.cast(), source_words.len());
            count_data.cast::<u32>().write(1);
        }
        let (upload, upload_data) = host.upload_buffer(bytes).unwrap();
        // SAFETY: upload_data is the mapped upload buffer returned above.
        unsafe {
            std::slice::from_raw_parts_mut(upload_data.cast::<u32>(), source_words.len())
                .fill(SENTINEL);
        }
        let readback_desc = D3D12_RESOURCE_DESC {
            Dimension: D3D12_RESOURCE_DIMENSION_BUFFER,
            Width: bytes,
            Height: 1,
            DepthOrArraySize: 1,
            MipLevels: 1,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Layout: D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
            ..Default::default()
        };
        let readback_heap = D3D12_HEAP_PROPERTIES {
            Type: D3D12_HEAP_TYPE_READBACK,
            ..Default::default()
        };
        let mut readback = None;
        // SAFETY: plain creation of a readback buffer on the host device.
        unsafe {
            host.device
                .CreateCommittedResource(
                    &readback_heap,
                    D3D12_HEAP_FLAG_NONE,
                    &readback_desc,
                    D3D12_RESOURCE_STATE_COPY_DEST,
                    None,
                    &mut readback,
                )
                .unwrap();
        }
        let readback = readback.unwrap();
        let list = host.new_list().unwrap();
        list.keep(&readback);

        // Inputs are read by the helper as ByteAddressBuffer SRVs.
        // SAFETY: all resources are live D3D12 buffers.
        let source_gpu = unsafe { source.GetGPUVirtualAddress() };
        // SAFETY: the count buffer is live.
        let count_gpu = unsafe { count.GetGPUVirtualAddress() };
        let source_to_read = crate::host::transition(
            &source,
            D3D12_RESOURCE_STATE_COMMON,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        );
        let count_to_read = crate::host::transition(
            &count,
            D3D12_RESOURCE_STATE_COMMON,
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
        );
        // These two helpers also record their production state transitions:
        // the budget is cleared before each submission; scratch is reused.
        let budget_gpu = list.budget().unwrap();
        let dst = list.indirect_scratch(bytes).unwrap();
        // SAFETY: the command list is open and all resources are alive.
        unsafe {
            list.list.ResourceBarrier(&[source_to_read, count_to_read]);
            list.list.ResourceBarrier(&[crate::host::transition(
                &dst,
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                D3D12_RESOURCE_STATE_COPY_DEST,
            )]);
            list.list.CopyBufferRegion(&dst, 0, &upload, 0, bytes);
            list.list.ResourceBarrier(&[crate::host::transition(
                &dst,
                D3D12_RESOURCE_STATE_COPY_DEST,
                D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
            )]);
        }

        let clamp = super::make_for(&host.device).unwrap();
        assert!(super::record_clamp(
            &clamp,
            &list.list,
            &dst,
            budget_gpu,
            source_gpu,
            Some(count_gpu),
            (0, 16, 3),
        ));
        list.indirect_ready();

        // Read back the output after the helper writes; restore the tracked
        // indirect state so HostList::close can return the scratch to COMMON.
        // SAFETY: ordered transitions and copies in one open command list.
        unsafe {
            list.list.ResourceBarrier(&[crate::host::transition(
                &dst,
                D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT,
                D3D12_RESOURCE_STATE_COPY_SOURCE,
            )]);
            list.list.CopyBufferRegion(&readback, 0, &dst, 0, bytes);
            list.list.ResourceBarrier(&[crate::host::transition(
                &dst,
                D3D12_RESOURCE_STATE_COPY_SOURCE,
                D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT,
            )]);
            list.list.ResourceBarrier(&[
                crate::host::transition(
                    &source,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_COMMON,
                ),
                crate::host::transition(
                    &count,
                    D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                    D3D12_RESOURCE_STATE_COMMON,
                ),
            ]);
        }
        list.close();
        host.execute(&[&list]);

        let mut mapped = std::ptr::null_mut();
        let range = D3D12_RANGE { Begin: 0, End: bytes as usize };
        // SAFETY: execution completed before mapping the readback resource.
        unsafe {
            readback.Map(0, Some(&range), Some(&mut mapped)).unwrap();
            let result = std::slice::from_raw_parts(mapped.cast::<u32>(), source_words.len());
            assert_eq!(&result[..4], &[0x11, 0x2, 0x3, 0x4]);
            assert_eq!(&result[4..], &[SENTINEL; 8]);
            readback.Unmap(0, None);
            let original = std::slice::from_raw_parts(source_data.cast::<u32>(), source_words.len());
            assert_eq!(original, &source_words, "the clamp must not modify the title's input buffer");
            assert_eq!(count_data.cast::<u32>().read(), 1);
        }
    }
}
