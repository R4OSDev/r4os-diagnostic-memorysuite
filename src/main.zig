const r4os = @import("r4os");
const std = @import("std");

const KB: u64 = 1024;
const MB: u64 = 1024 * KB;
const GB: u64 = 1024 * MB;
const PAGE_SIZE: u64 = 4096;
const backing_store_path = "C:\\TEMP\\MEMPAGE.BIN";
const missing_backing_store_path = "C:\\TEMP\\MEMMISS.SWP";
const backing_store_bytes: u64 = 64 * KB;
const backing_store_slot_count: u64 = backing_store_bytes / PAGE_SIZE;
const backing_store_slot_reserve: u64 = 4;
const backing_store_slot_owner: u32 = 0x4D454D53;
const backing_store_gate_bytes: u64 = 8 * PAGE_SIZE;
const pager_stress_cycles: u32 = 3;
const pager_stress_region_pages: u64 = 8;
const pager_stress_io_pages: u64 = 4;
const pager_stress_small_regions: usize = 12;
// 0.56.40: hz-neutral in ms (bei 100 Hz wie zuvor 100/250/100 Ticks);
// Umrechnung zur Laufzeit via ticksFromMilliseconds (0.56.29-Falle 2:
// diese Schwellen schlugen bei der 1000-Hz-Probe als FATAL-strict zu).
const pager_stress_max_storage_completion_ms: u64 = 1000;
const pager_stress_max_fs_ms: u64 = 2500;
const pager_stress_max_reclaim_ms: u64 = 1000;
const pager_stress_max_service_queue_high_water: u32 = 16;
const program_lifecycle_timeout_ms: u64 = 10_000;
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;

const tracked_kind_program_image = r4os.abi.memory_kind_program_image;
const tracked_kind_virtual_range = r4os.abi.memory_kind_virtual_range;
const tracked_kind_app_stack = r4os.abi.memory_kind_app_stack;
const tracked_owner_r4x = r4os.abi.memory_owner_r4x_instance;

var touch_sink: u8 = 0;

const ResourceTotals = struct {
    blocks: u64 = 0,
    program_images: u64 = 0,
    vm_ranges: u64 = 0,
    app_stacks: u64 = 0,
    reserved: u64 = 0,
    committed: u64 = 0,
    physical: u64 = 0,
    virtual: u64 = 0,
};

const VmStressStats = struct {
    reserved_bytes: u64 = 0,
    committed_bytes: u64 = 0,
    resident_bytes: u64 = 0,
    peak_resident_bytes: u64 = 0,
    touched_pages: u64 = 0,
    page_faults: u64 = 0,
    failed_faults: u64 = 0,
    decommits: u64 = 0,
    limit_errors: u64 = 0,
    table_before: u64 = 0,
    table_during: u64 = 0,
    table_after: u64 = 0,
    cleanup_ok: bool = false,
};

const PagerStressStats = struct {
    small_regions: u64 = 0,
    cycles: u64 = 0,
    page_outs: u64 = 0,
    fault_ins: u64 = 0,
    reclaim_frames: u64 = 0,
    retryable_failures: u64 = 0,
    permanent_failures: u64 = 0,
    data_preserved: u64 = 0,
    data_lost: u64 = 0,
    // Die drei Maxima laufen im Kernel seit dem Boot und werden nie
    // zurueckgesetzt. Ohne den Vorher-Wert laesst sich nicht sagen, ob ein
    // Ausschlag aus DIESEM Lauf stammt - deshalb beide.
    storage_completion_max_ticks_before: u64 = 0,
    fs_max_ticks_before: u64 = 0,
    reclaim_max_ticks_before: u64 = 0,
    storage_completion_max_ticks: u64 = 0,
    fs_max_ticks: u64 = 0,
    reclaim_max_ticks: u64 = 0,
    storage_worker_requests: u64 = 0,
    storage_worker_completions: u64 = 0,
    storage_completion_signals: u64 = 0,
    storage_completion_timeouts: u64 = 0,
    fs_lock_timeouts: u64 = 0,
    service_completion_timeouts: u64 = 0,
    long_running_warnings: u64 = 0,
    starvation_warnings: u64 = 0,
    lock_contention_timeouts: u64 = 0,
    lock_sleep_under_lock: u64 = 0,
    lock_sleep_under_no_sleep_lock: u64 = 0,
    service_queue_high_water: u32 = 0,
    cleanup_ok: bool = false,
};

const MultiGbProfile = struct {
    name: []const u8,
    reserve_bytes: u64,
    commit_bytes: u64,
    touch_bytes: u64,
};

const DiagApi = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?DiagApi {
        return .{
            .sys = r4_app.system(),
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }
};

const App = struct {
    ctx: *DiagApi,
    strict: bool = false,

    fn run(self: *App) i32 {
        const args = self.ctx.sys.argsRaw();
        self.strict = argsContain(args, "/STRICT");
        const expect_fail = argsContain(args, "/EXPECTFAIL");
        const vmstress = argsContain(args, "/VMSTRESS");
        const multigb = argsContain(args, "/MULTIGB");
        const pagerstress = argsContain(args, "/PAGERSTRESS");

        self.ctx.sys.println("MEMSUITE");
        if (!self.ctx.sys.hasFn("vm_reserve")) return self.finish(false, "vm api missing");
        if (!self.ctx.sys.base.hasDevFn("performance_summary")) return self.finish(false, "vm region stats api missing");
        if (!self.ctx.dev.hasFn("memory_summary")) return self.finish(false, "memory snapshot api missing");
        if (!self.ctx.dev.hasFn("memory_pressure_snapshot")) return self.finish(false, "memory pressure api missing");
        if (!self.ctx.dev.hasFn("memory_reclaim_probe")) return self.finish(false, "fs reclaim api missing");
        if (!self.ctx.dev.hasFn("memory_reclaim_probe")) return self.finish(false, "fs pmm reclaim api missing");
        if (!self.ctx.dev.hasFn("memory_reclaim_probe")) return self.finish(false, "global reclaim api missing");
        if (!self.ctx.dev.hasFn("memory_backing_store_probe")) return self.finish(false, "backing store api missing");
        if (!self.ctx.dev.hasFn("memory_backing_store_slot_probe")) return self.finish(false, "backing store slot api missing");
        if (!self.ctx.dev.hasFn("memory_pager_gate_probe")) return self.finish(false, "pager gate api missing");
        if (!self.ctx.dev.hasFn("memory_page_io_probe")) return self.finish(false, "page io api missing");
        if (!self.ctx.dev.hasFn("memory_page_io_probe")) return self.finish(false, "fault page-in api missing");
        if (!self.ctx.dev.hasFn("memory_pressure_snapshot")) return self.finish(false, "memory eviction api missing");
        if (!self.ctx.dev.hasFn("memory_pager_gate_probe")) return self.finish(false, "pager error policy api missing");

        if (multigb) return self.finish(self.testMultiGbProfile(), "multigb mismatch");
        if (pagerstress) return self.finish(self.testPagerStressProfile(), "pagerstress mismatch");
        if (vmstress) return self.finish(self.testVmStressProfile(), "vmstress mismatch");

        var ok = true;
        ok = self.testMemoryPressure() and ok;
        ok = self.testLocalAllocator() and ok;
        ok = self.testRepeatedProgramCleanup("APPHEAPD", "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X", "", 4) and ok;
        ok = self.testRepeatedProgramCleanup("STACKD", "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\STACKD.R4X", "", 4) and ok;
        ok = self.testKillWhileHolding() and ok;

        const summary = self.ctx.dev.memorySummary() orelse return self.finish(false, "summary unavailable");
        self.ctx.sys.write("MEMSUITE memory active=");
        self.ctx.sys.printU64(summary.active_blocks);
        self.ctx.sys.write(" released=");
        self.ctx.sys.printU64(summary.released_blocks);
        self.ctx.sys.write(" committed=");
        self.ctx.sys.printU64(summary.committed_bytes);
        self.ctx.sys.println("");

        if (expect_fail) {
            self.ctx.sys.println("MEMSUITE expected-failure variant triggered");
            ok = false;
        }
        return self.finish(ok, "suite mismatch");
    }

    fn finish(self: *App, ok: bool, msg: []const u8) i32 {
        if (ok) {
            self.ctx.sys.println("MEMSUITE result: OK");
            return 0;
        }
        self.ctx.sys.write("MEMSUITE result: FAILED ");
        self.ctx.sys.println(msg);
        if (self.strict) {
            self.ctx.sys.println("FATAL: MEMSUITE strict failure");
            self.ctx.sys.systemPoweroff();
        }
        return 1;
    }

    fn testVmStressProfile(self: *App) bool {
        self.ctx.sys.println("MEMSUITE vmstress");
        const current = self.currentMemoryInfo() orelse return self.failBool("vmstress current owner unavailable");
        const owner_id = current.id;
        // Service and shell owners may allocate or release independent VM
        // regions while this profile runs.  Leak accounting therefore binds
        // to the exact MEMSUITE owner; spawned-child cleanup is checked
        // separately by owner ID in testKillCommittedVm.
        const before = self.resourceTotalsForOwner(owner_id);
        var stats = VmStressStats{
            .table_before = self.resourceTotals().blocks,
            .table_during = self.resourceTotals().blocks,
        };

        var ok = true;
        ok = self.testMemoryPressure() and ok;
        ok = self.testVmReserveMatrix(&stats) and ok;
        ok = self.testDemandCommitStats(&stats, 256 * MB, 64 * MB, 8 * MB) and ok;
        ok = self.testVmLimitAccounting(&stats) and ok;
        ok = self.testKillCommittedVm(&stats) and ok;

        const after = self.resourceTotalsForOwner(owner_id);
        stats.table_after = self.resourceTotals().blocks;
        stats.cleanup_ok = sameTotals(before, after);
        if (!stats.cleanup_ok) {
            self.printTotals("vmstress-before", before);
            self.printTotals("vmstress-after", after);
            ok = self.failBool("vmstress cleanup mismatch") and ok;
        }

        self.printVmStressStats("vmstress", stats);
        if (ok) self.ctx.sys.println("MEMSUITE VM stress result: OK");
        return ok;
    }

    fn testMemoryPressure(self: *App) bool {
        self.ctx.sys.println("MEMSUITE memory pressure");
        const p = self.ctx.dev.memoryPressure() orelse return self.failBool("pressure snapshot unavailable");
        const summary = self.ctx.dev.memorySummary() orelse return self.failBool("pressure memory summary unavailable");
        const perf = self.ctx.dev.performanceSummary() orelse return self.failBool("pressure performance summary unavailable");
        const expected_nonresident = if (p.virtual_committed_bytes > p.virtual_resident_bytes)
            p.virtual_committed_bytes - p.virtual_resident_bytes
        else
            0;
        const required_flags = r4os.abi.memory_pressure_flag_no_pagefile |
            r4os.abi.memory_pressure_flag_no_swap |
            r4os.abi.memory_pressure_flag_commit_limited |
            r4os.abi.memory_pressure_flag_demand_commit |
            r4os.abi.memory_pressure_flag_profile_limits |
            r4os.abi.memory_pressure_flag_fs_cache_reclaim;
        const required_oom = r4os.abi.memory_pressure_oom_alloc_returns_null |
            r4os.abi.memory_pressure_oom_vm_returns_error |
            r4os.abi.memory_pressure_oom_fault_escalates |
            r4os.abi.memory_pressure_oom_no_overcommit;

        var ok = true;
        if (p.version != r4os.abi.memory_pressure_snapshot_version) ok = self.failBool("pressure version") and ok;
        if (p.size < @sizeOf(r4os.abi.ProgramMemoryPressureSnapshot)) ok = self.failBool("pressure size") and ok;
        if ((p.flags & required_flags) != required_flags) ok = self.failBool("pressure flags") and ok;
        if ((p.oom_policy_flags & required_oom) != required_oom) ok = self.failBool("pressure oom flags") and ok;
        if (p.pressure_level < r4os.abi.memory_pressure_level_normal or p.pressure_level > r4os.abi.memory_pressure_level_critical) ok = self.failBool("pressure level") and ok;
        if (p.total_physical_bytes == 0 or p.free_physical_bytes == 0) ok = self.failBool("pressure physical bytes") and ok;
        if (p.used_physical_bytes + p.free_physical_bytes != p.total_physical_bytes) ok = self.failBool("pressure physical accounting") and ok;
        if (p.largest_free_physical_bytes > p.free_physical_bytes or p.largest_free_physical_bytes != summary.largest_free_phys_len) ok = self.failBool("pressure largest physical") and ok;
        if (p.virtual_committed_bytes < p.virtual_resident_bytes) ok = self.failBool("pressure resident > committed") and ok;
        if (p.committed_nonresident_bytes != expected_nonresident) ok = self.failBool("pressure nonresident") and ok;
        if (p.commit_budget_bytes < p.virtual_resident_bytes or p.commit_headroom_bytes > p.commit_budget_bytes) ok = self.failBool("pressure commit budget") and ok;
        if ((p.flags & r4os.abi.memory_pressure_flag_no_reclaim) != 0) ok = self.failBool("pressure false no-reclaim") and ok;
        if (!pressureReclaimSourcesOk(p, perf)) ok = self.failBool("pressure pmm reclaim") and ok;
        if (!pressureDirtySourcesOk(p, perf)) ok = self.failBool("pressure pmm dirty") and ok;
        if (p.non_reclaimable_bytes + p.reclaimable_bytes != p.used_physical_bytes) ok = self.failBool("pressure nonreclaimable") and ok;
        if ((perf.flags & r4os.abi.performance_flag_fs_reclaim_ready) == 0) ok = self.failBool("pressure fs reclaim flag") and ok;
        if ((perf.flags & r4os.abi.performance_flag_fs_pmm_reclaim_ready) == 0) ok = self.failBool("pressure fs pmm flag") and ok;
        if ((perf.flags & r4os.abi.performance_flag_global_reclaim_ready) == 0) ok = self.failBool("pressure global reclaim flag") and ok;
        if ((perf.flags & r4os.abi.performance_flag_memory_pager_error_policy_ready) == 0) ok = self.failBool("pressure pager policy flag") and ok;
        if (perf.fs_cache_clean_reclaimable_bytes == 0 or perf.fs_cache_clean_reclaimable_entries == 0) ok = self.failBool("pressure fs clean reclaim") and ok;
        if (perf.fs_cache_payload_frame_bytes < 4096 or perf.fs_cache_payload_frames < perf.fs_cache_entries_used) ok = self.failBool("pressure fs payload frames") and ok;
        if (perf.fs_cache_pmm_reclaimable_bytes < perf.fs_cache_clean_reclaimable_bytes) ok = self.failBool("pressure fs pmm bytes") and ok;
        if (perf.fs_cache_payload_allocations == 0 or perf.fs_cache_payload_allocation_failures != 0) ok = self.failBool("pressure fs payload alloc") and ok;
        if (perf.fs_cache_dirty_non_reclaimable_bytes != perf.fs_cache_dirty_bytes) ok = self.failBool("pressure fs dirty split") and ok;
        if (perf.fs_cache_pmm_dirty_bytes != 0) ok = self.failBool("pressure fs pmm dirty") and ok;
        if (perf.fs_cache_dirty_non_reclaimable_entries != perf.fs_cache_dirty_entries) ok = self.failBool("pressure fs dirty entries") and ok;
        if (perf.fs_cache_pagefile_ready != 0 or !pagefileBlockersOk(perf.fs_cache_pagefile_blockers)) ok = self.failBool("pressure pagefile blockers") and ok;
        if (perf.fs_cache_reclaim_failed_drains != 0) ok = self.failBool("pressure reclaim failures") and ok;

        const reclaim_probe = self.ctx.dev.memoryReclaimProbe(1) orelse {
            ok = self.failBool("pressure global reclaim unavailable") and ok;
            return ok;
        };
        const perf_after = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure performance after reclaim unavailable") and ok;
            return ok;
        };
        const p_after = self.ctx.dev.memoryPressure() orelse {
            ok = self.failBool("pressure snapshot after reclaim unavailable") and ok;
            return ok;
        };
        const expected_reclaim_bytes = @as(u64, reclaim_probe.returned_frames) * @as(u64, perf.fs_cache_payload_frame_bytes);
        if (reclaim_probe.version != r4os.abi.memory_reclaim_probe_version) ok = self.failBool("pressure reclaim version") and ok;
        if (reclaim_probe.size < @sizeOf(r4os.abi.ProgramMemoryReclaimProbe)) ok = self.failBool("pressure reclaim size") and ok;
        if (reclaim_probe.reason != r4os.abi.memory_reclaim_reason_diagnostic) ok = self.failBool("pressure reclaim reason") and ok;
        if (reclaim_probe.requested_frames != 1 or reclaim_probe.returned_frames == 0) ok = self.failBool("pressure reclaim frames") and ok;
        if (reclaim_probe.returned_bytes < expected_reclaim_bytes) ok = self.failBool("pressure reclaim bytes") and ok;
        if (reclaim_probe.failed_drains != 0 or perf_after.global_reclaim_failed_drains != 0) ok = self.failBool("pressure reclaim drain failures") and ok;
        if (reclaim_probe.after_free_frames < reclaim_probe.before_free_frames + reclaim_probe.returned_frames) ok = self.failBool("pressure reclaim free frames") and ok;
        if (perf_after.global_reclaim_attempts < perf.global_reclaim_attempts + 1) ok = self.failBool("pressure global attempts") and ok;
        if (perf_after.global_reclaim_successes < perf.global_reclaim_successes + 1) ok = self.failBool("pressure global successes") and ok;
        if (perf_after.global_reclaim_returned_frames < perf.global_reclaim_returned_frames + reclaim_probe.returned_frames) ok = self.failBool("pressure global returned frames") and ok;
        if (perf_after.global_reclaim_last_reason != r4os.abi.memory_reclaim_reason_diagnostic) ok = self.failBool("pressure global last reason") and ok;
        if (perf_after.global_reclaim_last_requested_frames != 1 or perf_after.global_reclaim_last_returned_frames != reclaim_probe.returned_frames) ok = self.failBool("pressure global last frames") and ok;
        if (!pressureReclaimSourcesOk(p_after, perf_after) or !pressureDirtySourcesOk(p_after, perf_after))
            ok = self.failBool("pressure after reclaim pmm") and ok;
        // The global reclaimer may satisfy the request from the independent
        // Task-stack cache before consulting FS or evictable VM pages. The
        // public pressure snapshot currently contains only those latter two
        // sources, so only their source-specific bytes may be subtracted from
        // reclaimable_bytes here.
        const snapshot_returned_bytes = reclaim_probe.fs_returned_bytes +| reclaim_probe.vm_returned_bytes;
        if (snapshot_returned_bytes > reclaim_probe.returned_bytes) ok = self.failBool("pressure reclaim source accounting") and ok;
        if (p_after.reclaimable_bytes +| snapshot_returned_bytes > p.reclaimable_bytes) ok = self.failBool("pressure reclaim accounting") and ok;

        const missing_backing = self.ctx.dev.memoryBackingStoreProbe(missing_backing_store_path, backing_store_bytes, 0) orelse {
            ok = self.failBool("pressure backing missing unavailable") and ok;
            return ok;
        };
        if (missing_backing.status != r4os.abi.memory_backing_store_status_missing_file or
            (missing_backing.blockers & r4os.abi.memory_backing_store_blocker_missing_file) == 0 or
            missing_backing.pager_enabled != 0 or missing_backing.anonymous_paging_enabled != 0)
        {
            ok = self.failBool("pressure backing missing") and ok;
        }
        if (!self.writeBackingStoreFile(backing_store_path, backing_store_bytes)) ok = self.failBool("pressure backing create") and ok;
        const backing = self.ctx.dev.memoryBackingStoreProbe(backing_store_path, backing_store_bytes, 0) orelse {
            ok = self.failBool("pressure backing unavailable") and ok;
            return ok;
        };
        const perf_backing = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure backing performance unavailable") and ok;
            return ok;
        };
        if ((perf_backing.flags & r4os.abi.performance_flag_memory_backing_store_ready) == 0) ok = self.failBool("pressure backing flag") and ok;
        if (backing.version != r4os.abi.memory_backing_store_probe_version) ok = self.failBool("pressure backing version") and ok;
        if (backing.size < @sizeOf(r4os.abi.ProgramMemoryBackingStoreProbe)) ok = self.failBool("pressure backing size") and ok;
        if (backing.status != r4os.abi.memory_backing_store_status_ready or perf_backing.memory_backing_store_status != r4os.abi.memory_backing_store_status_ready) ok = self.failBool("pressure backing status") and ok;
        if (!backingStoreReadyFlagsOk(backing.flags) or !backingStoreReadyFlagsOk(perf_backing.memory_backing_store_flags)) ok = self.failBool("pressure backing flags") and ok;
        if (backing.blockers != 0 or perf_backing.memory_backing_store_blockers != 0) ok = self.failBool("pressure backing blockers") and ok;
        if (backing.requested_bytes != backing_store_bytes or perf_backing.memory_backing_store_requested_bytes != backing_store_bytes) ok = self.failBool("pressure backing request") and ok;
        if (backing.available_bytes < backing_store_bytes or backing.file_size < backing_store_bytes) ok = self.failBool("pressure backing capacity") and ok;
        if (backing.cluster_bytes < 512 or backing.first_cluster == 0) ok = self.failBool("pressure backing fat32") and ok;
        if (backing.pager_enabled != 0 or backing.anonymous_paging_enabled != 0) ok = self.failBool("pressure backing pager") and ok;
        if (perf_backing.memory_backing_store_probe_count < missing_backing.total_probes + 1 or
            perf_backing.memory_backing_store_ready_count == 0 or
            perf_backing.memory_backing_store_failure_count == 0)
        {
            ok = self.failBool("pressure backing counters") and ok;
        }

        const missing_slots = self.ctx.dev.memoryBackingStoreSlotProbe(missing_backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot missing unavailable") and ok;
            return ok;
        };
        if (missing_slots.status != r4os.abi.memory_backing_store_slot_status_backing_unavailable or
            (missing_slots.blockers & r4os.abi.memory_backing_store_slot_blocker_backing_not_ready) == 0)
        {
            ok = self.failBool("pressure slot missing") and ok;
        }
        const slot_capacity = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot capacity unavailable") and ok;
            return ok;
        };
        if (slot_capacity.status != r4os.abi.memory_backing_store_slot_status_ready or
            !backingStoreSlotFlagsOk(slot_capacity.flags) or
            slot_capacity.slot_bytes != PAGE_SIZE or
            slot_capacity.capacity_slots < backing_store_slot_count or
            slot_capacity.reserved_slots != 0 or
            slot_capacity.free_slots != slot_capacity.capacity_slots)
        {
            ok = self.failBool("pressure slot capacity") and ok;
        }
        const slot_over = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, slot_capacity.capacity_slots + 1, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot over unavailable") and ok;
            return ok;
        };
        if (slot_over.status != r4os.abi.memory_backing_store_slot_status_insufficient_capacity or
            (slot_over.blockers & r4os.abi.memory_backing_store_slot_blocker_insufficient_capacity) == 0)
        {
            ok = self.failBool("pressure slot over capacity") and ok;
        }
        const slot_reserve = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, backing_store_slot_reserve, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot reserve unavailable") and ok;
            return ok;
        };
        if (slot_reserve.status != r4os.abi.memory_backing_store_slot_status_reserved or
            slot_reserve.reservation_id == 0 or
            slot_reserve.reserved_slots != backing_store_slot_reserve or
            slot_reserve.range_count != 1)
        {
            ok = self.failBool("pressure slot reserve") and ok;
        }
        const slot_mark = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_mark_error, 0, slot_reserve.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot mark unavailable") and ok;
            return ok;
        };
        const slot_recover = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_recover, 0, slot_reserve.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot recover unavailable") and ok;
            return ok;
        };
        const slot_release = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, slot_reserve.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot release unavailable") and ok;
            return ok;
        };
        const slot_final = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure slot final unavailable") and ok;
            return ok;
        };
        const perf_slots = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure slot performance unavailable") and ok;
            return ok;
        };
        if (slot_mark.status != r4os.abi.memory_backing_store_slot_status_error_marked or slot_mark.error_slots != backing_store_slot_reserve) ok = self.failBool("pressure slot mark") and ok;
        if (slot_recover.status != r4os.abi.memory_backing_store_slot_status_recovered or slot_recover.error_slots != 0) ok = self.failBool("pressure slot recover") and ok;
        if (slot_release.status != r4os.abi.memory_backing_store_slot_status_released or slot_release.reserved_slots != 0) ok = self.failBool("pressure slot release") and ok;
        if ((perf_slots.flags & r4os.abi.performance_flag_memory_backing_store_slots_ready) == 0 or
            perf_slots.memory_backing_store_slot_status != r4os.abi.memory_backing_store_slot_status_ready or
            perf_slots.memory_backing_store_slot_operation != r4os.abi.memory_backing_store_slot_operation_probe or
            perf_slots.memory_backing_store_slot_capacity < backing_store_slot_count or
            perf_slots.memory_backing_store_slot_reserved != 0 or
            perf_slots.memory_backing_store_slot_free != perf_slots.memory_backing_store_slot_capacity or
            perf_slots.memory_backing_store_slot_error != 0 or
            perf_slots.memory_backing_store_slot_reserve_count == 0 or
            perf_slots.memory_backing_store_slot_release_count == 0 or
            perf_slots.memory_backing_store_slot_error_mark_count == 0 or
            perf_slots.memory_backing_store_slot_recovery_count == 0 or
            perf_slots.memory_backing_store_slot_failure_count == 0 or
            perf_slots.memory_backing_store_slot_pager_enabled != 0 or
            perf_slots.memory_backing_store_slot_eviction_enabled != 1 or
            perf_slots.memory_backing_store_slot_page_in_enabled != 1 or
            perf_slots.memory_backing_store_slot_page_out_enabled != 1 or
            slot_final.reserved_slots != 0)
        {
            ok = self.failBool("pressure slot summary") and ok;
        }

        const gate_region = self.ctx.sys.vmReserve(backing_store_gate_bytes * 2, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse {
            ok = self.failBool("pressure gate reserve unavailable") and ok;
            return ok;
        };
        var gate_release_needed = true;
        defer {
            if (gate_release_needed) _ = self.ctx.sys.vmRelease(gate_region.id);
        }
        const gate_empty = self.ctx.dev.memoryPagerGateProbe(backing_store_path, backing_store_bytes, gate_region.id, 0, 0) orelse {
            ok = self.failBool("pressure gate empty unavailable") and ok;
            return ok;
        };
        if (gate_empty.status != r4os.abi.memory_pager_gate_status_no_nonresident_commit or
            (gate_empty.blockers & r4os.abi.memory_pager_gate_blocker_no_nonresident_commit) == 0)
        {
            ok = self.failBool("pressure gate empty") and ok;
        }
        if (self.ctx.sys.vmCommit(gate_region.id, 0, backing_store_gate_bytes) != r4os.abi.vm_ok) {
            ok = self.failBool("pressure gate commit") and ok;
            return ok;
        }
        const gate_missing = self.ctx.dev.memoryPagerGateProbe(missing_backing_store_path, backing_store_bytes, gate_region.id, 0, 0) orelse {
            ok = self.failBool("pressure gate missing unavailable") and ok;
            return ok;
        };
        if (gate_missing.status != r4os.abi.memory_pager_gate_status_backing_unavailable or
            (gate_missing.blockers & r4os.abi.memory_pager_gate_blocker_backing_not_ready) == 0)
        {
            ok = self.failBool("pressure gate missing backing") and ok;
        }
        const gate_over = self.ctx.dev.memoryPagerGateProbe(backing_store_path, backing_store_bytes, gate_region.id, backing_store_bytes + PAGE_SIZE, 0) orelse {
            ok = self.failBool("pressure gate over unavailable") and ok;
            return ok;
        };
        if (gate_over.status != r4os.abi.memory_pager_gate_status_insufficient_capacity or
            (gate_over.blockers & r4os.abi.memory_pager_gate_blocker_insufficient_capacity) == 0)
        {
            ok = self.failBool("pressure gate over capacity") and ok;
        }
        const gate_ready = self.ctx.dev.memoryPagerGateProbe(backing_store_path, backing_store_bytes, gate_region.id, 0, 0) orelse {
            ok = self.failBool("pressure gate ready unavailable") and ok;
            return ok;
        };
        if (gate_ready.status != r4os.abi.memory_pager_gate_status_ready or
            !pagerGateFlagsOk(gate_ready.flags) or
            gate_ready.requested_bytes != backing_store_gate_bytes or
            gate_ready.committed_bytes != backing_store_gate_bytes or
            gate_ready.resident_bytes != 0 or
            gate_ready.nonresident_bytes != backing_store_gate_bytes or
            gate_ready.prepared_slots != backing_store_gate_bytes / PAGE_SIZE or
            gate_ready.free_after_slots != gate_ready.capacity_slots or
            gate_ready.reserved_after_slots != 0 or
            gate_ready.rollback_completed != 1 or
            gate_ready.pager_enabled != 0 or
            gate_ready.eviction_enabled != 1 or
            gate_ready.page_in_enabled != 0 or
            gate_ready.page_out_enabled != 0)
        {
            ok = self.failBool("pressure gate ready") and ok;
        }
        const perf_gate = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure gate performance unavailable") and ok;
            return ok;
        };
        if ((perf_gate.flags & r4os.abi.performance_flag_memory_pager_gates_ready) == 0 or
            perf_gate.memory_pager_gate_status != r4os.abi.memory_pager_gate_status_ready or
            perf_gate.memory_pager_gate_prepared_slots != backing_store_gate_bytes / PAGE_SIZE or
            perf_gate.memory_pager_gate_reserved_after_slots != 0 or
            perf_gate.memory_pager_gate_rollback_completed != 1 or
            perf_gate.memory_pager_gate_probe_count < 4 or
            perf_gate.memory_pager_gate_ready_count == 0 or
            perf_gate.memory_pager_gate_failure_count == 0 or
            perf_gate.memory_pager_gate_pager_enabled != 0 or
            perf_gate.memory_pager_gate_eviction_enabled != 1 or
            perf_gate.memory_pager_gate_page_in_enabled != 0 or
            perf_gate.memory_pager_gate_page_out_enabled != 0)
        {
            ok = self.failBool("pressure gate summary") and ok;
        }

        const page_io_count: u64 = 2;
        const page_io_bytes: u64 = PAGE_SIZE * page_io_count;
        const page_slot = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, page_io_count, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure page io slot unavailable") and ok;
            return ok;
        };
        var page: [8192]u8 = undefined;
        var expected: [8192]u8 = undefined;
        var page_index: usize = 0;
        while (page_index < page.len) : (page_index += 1) {
            const value: u8 = @truncate(page_index *% 7 +% 0x42);
            page[page_index] = value;
            expected[page_index] = value;
        }
        const page_invalid = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_slot.generation, page[0..], 0) orelse {
            ok = self.failBool("pressure page io invalid unavailable") and ok;
            return ok;
        };
        const page_missing = self.ctx.dev.memoryPageIoProbe(missing_backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_slot.generation, page[0..], r4os.abi.memory_page_io_flag_retry_request) orelse {
            ok = self.failBool("pressure page io missing unavailable") and ok;
            return ok;
        };
        const page_out = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_slot.generation, page[0..], 0) orelse {
            ok = self.failBool("pressure page io out unavailable") and ok;
            return ok;
        };
        const page_mark = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_mark_error, 0, page_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure page io mark unavailable") and ok;
            return ok;
        };
        const page_error = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_mark.generation, page[0..], r4os.abi.memory_page_io_flag_retry_request) orelse {
            ok = self.failBool("pressure page io error unavailable") and ok;
            return ok;
        };
        const page_recover = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_recover, 0, page_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure page io recover unavailable") and ok;
            return ok;
        };
        const page_retry = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_recover.generation, expected[0..], r4os.abi.memory_page_io_flag_retry_request) orelse {
            ok = self.failBool("pressure page io retry unavailable") and ok;
            return ok;
        };
        @memset(page[0..], 0);
        const page_in = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, gate_region.id, 0, page_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, page_retry.slot_generation, page[0..], 0) orelse {
            ok = self.failBool("pressure page io in unavailable") and ok;
            return ok;
        };
        const page_perf = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure page io performance unavailable") and ok;
            return ok;
        };
        if (page_invalid.status != r4os.abi.memory_page_io_status_slot_not_valid or
            page_missing.status != r4os.abi.memory_page_io_status_backing_unavailable or
            (page_missing.flags & r4os.abi.memory_page_io_flag_retryable_failure) == 0 or
            (page_missing.flags & r4os.abi.memory_page_io_flag_data_preserved) == 0 or
            page_out.status != r4os.abi.memory_page_io_status_page_out_ok or
            page_mark.status != r4os.abi.memory_backing_store_slot_status_error_marked or
            page_error.status != r4os.abi.memory_page_io_status_slot_error or
            (page_error.flags & r4os.abi.memory_page_io_flag_permanent_failure) == 0 or
            page_recover.status != r4os.abi.memory_backing_store_slot_status_recovered or
            page_recover.valid_slots != 0 or
            page_recover.error_slots != 0 or
            page_retry.status != r4os.abi.memory_page_io_status_page_out_ok or
            !pageIoFlagsOk(page_retry.flags, r4os.abi.memory_page_io_operation_page_out) or
            (page_retry.flags & r4os.abi.memory_page_io_flag_retry_request) == 0 or
            page_retry.page_count != page_io_count or
            page_retry.transfer_bytes != page_io_bytes or
            page_in.status != r4os.abi.memory_page_io_status_page_in_ok or
            !pageIoFlagsOk(page_out.flags, r4os.abi.memory_page_io_operation_page_out) or
            !pageIoFlagsOk(page_in.flags, r4os.abi.memory_page_io_operation_page_in) or
            !bytesEqual(page[0..], expected[0..]) or
            page_in.owner_id != backing_store_slot_owner or
            page_in.page_count != page_io_count or
            page_in.transfer_bytes != page_io_bytes or
            page_in.expected_generation != page_retry.slot_generation or
            @as(u64, page_in.io_bytes) != page_io_bytes or
            page_in.io_status != @as(i32, @intCast(page_io_bytes)) or
            page_in.pager_enabled != 0 or
            page_in.eviction_enabled != 1 or
            (page_perf.flags & r4os.abi.performance_flag_memory_page_io_ready) == 0 or
            (page_perf.flags & r4os.abi.performance_flag_memory_pager_error_policy_ready) == 0 or
            page_perf.memory_page_io_owner_id != backing_store_slot_owner or
            page_perf.memory_page_io_page_count != page_io_count or
            page_perf.memory_page_io_transfer_bytes != page_io_bytes or
            page_perf.memory_page_io_expected_generation != page_retry.slot_generation or
            page_perf.memory_page_io_page_out_count == 0 or
            page_perf.memory_page_io_page_in_count == 0 or
            page_perf.memory_page_io_failure_count == 0 or
            page_perf.memory_page_io_retry_attempt_count == 0 or
            page_perf.memory_page_io_retryable_failure_count == 0 or
            page_perf.memory_page_io_permanent_failure_count == 0 or
            page_perf.memory_page_io_retry_limit_hit_count == 0 or
            page_perf.memory_page_io_failed_page_out_count == 0 or
            page_perf.memory_page_io_failed_page_in_count == 0 or
            page_perf.memory_page_io_data_preserved_pages == 0 or
            page_perf.memory_page_io_data_lost_pages != 0 or
            page_perf.memory_page_io_pager_enabled != 0 or
            page_perf.memory_page_io_eviction_enabled != 1)
        {
            ok = self.failBool("pressure page io") and ok;
        }
        const page_release = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, page_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0) orelse {
            ok = self.failBool("pressure page io release unavailable") and ok;
            return ok;
        };
        if (page_release.status != r4os.abi.memory_backing_store_slot_status_released) ok = self.failBool("pressure page io release") and ok;
        _ = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_probe, 0, 0, r4os.abi.memory_backing_store_slot_owner_kind_diagnostic, backing_store_slot_owner, 0, 0);

        const fault_region = self.ctx.sys.vmReserve(page_io_bytes, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse {
            ok = self.failBool("pressure fault page-in reserve unavailable") and ok;
            return ok;
        };
        var fault_region_release_needed = true;
        defer {
            if (fault_region_release_needed) _ = self.ctx.sys.vmRelease(fault_region.id);
        }
        if (self.ctx.sys.vmCommit(fault_region.id, 0, page_io_bytes) != r4os.abi.vm_ok) {
            ok = self.failBool("pressure fault page-in commit") and ok;
            return ok;
        }
        const fault_region_info = self.ctx.sys.vmQuery(fault_region.id) orelse {
            ok = self.failBool("pressure fault page-in query unavailable") and ok;
            return ok;
        };
        if (fault_region_info.owner_id > 0xFFFF_FFFF) {
            ok = self.failBool("pressure fault page-in owner") and ok;
            return ok;
        }
        const fault_owner_id: u32 = @intCast(fault_region_info.owner_id);
        const fault_slot = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, page_io_count, 0, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, fault_owner_id, fault_region.id, 0) orelse {
            ok = self.failBool("pressure fault page-in slot unavailable") and ok;
            return ok;
        };
        var fault_slot_release_needed = true;
        defer {
            if (fault_slot_release_needed) _ = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, fault_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, fault_owner_id, fault_region.id, 0);
        }
        if (fault_slot.status != r4os.abi.memory_backing_store_slot_status_reserved or
            fault_slot.owner_kind != r4os.abi.memory_backing_store_slot_owner_kind_vm_region or
            fault_slot.owner_id != fault_owner_id or
            fault_slot.region_id != fault_region.id)
        {
            ok = self.failBool("pressure fault page-in slot") and ok;
        }

        const fault_ptr: [*]u8 = @ptrFromInt(fault_region_info.base);
        page_index = 0;
        while (page_index < expected.len) : (page_index += 1) {
            expected[page_index] = @truncate(page_index *% 5 +% 0x51);
            fault_ptr[page_index] = expected[page_index];
        }
        const before_fault_out = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure fault page-in pre-out unavailable") and ok;
            return ok;
        };
        const fault_out = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, fault_region.id, 0, fault_slot.reservation_id, 0, page_io_count, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, fault_owner_id, fault_slot.generation, fault_ptr[0..8192], 0) orelse {
            ok = self.failBool("pressure fault page-in out unavailable") and ok;
            return ok;
        };
        const after_fault_out_state = self.ctx.dev.memoryVmPageStateProbe(fault_region.id, 0, page_io_count, r4os.abi.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse {
            ok = self.failBool("pressure fault page-in out state unavailable") and ok;
            return ok;
        };
        const after_fault_out = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure fault page-in out performance unavailable") and ok;
            return ok;
        };
        const before_fault_in = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure fault page-in pre-in unavailable") and ok;
            return ok;
        };
        const fault_byte0 = fault_ptr[0];
        const fault_byte1 = fault_ptr[PAGE_SIZE + 31];
        const after_fault_in_state = self.ctx.dev.memoryVmPageStateProbe(fault_region.id, 0, page_io_count, r4os.abi.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse {
            ok = self.failBool("pressure fault page-in state unavailable") and ok;
            return ok;
        };
        const after_fault_in = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure fault page-in performance unavailable") and ok;
            return ok;
        };
        if (fault_out.status != r4os.abi.memory_page_io_status_page_out_ok or
            !pageIoFlagsOk(fault_out.flags, r4os.abi.memory_page_io_operation_page_out) or
            after_fault_out_state.status != r4os.abi.memory_vm_page_state_status_ready or
            after_fault_out_state.nonresident_pages < page_io_count or
            after_fault_out_state.slot_bound_pages < page_io_count or
            after_fault_out.memory_vm_page_state_page_out_nonresident_pages < before_fault_out.memory_vm_page_state_page_out_nonresident_pages + page_io_count or
            fault_byte0 != expected[0] or
            fault_byte1 != expected[PAGE_SIZE + 31] or
            after_fault_in_state.status != r4os.abi.memory_vm_page_state_status_ready or
            after_fault_in_state.resident_pages < page_io_count or
            after_fault_in_state.slot_bound_pages < page_io_count or
            after_fault_in.memory_vm_page_state_fault_page_in_count < before_fault_in.memory_vm_page_state_fault_page_in_count + page_io_count or
            after_fault_in.memory_page_io_page_in_count < before_fault_in.memory_page_io_page_in_count + page_io_count or
            after_fault_in.memory_page_io_status != r4os.abi.memory_page_io_status_page_in_ok or
            after_fault_in.memory_page_io_owner_kind != r4os.abi.memory_backing_store_slot_owner_kind_vm_region or
            after_fault_in.memory_page_io_page_count != 1 or
            after_fault_in.memory_page_io_region_offset != PAGE_SIZE or
            after_fault_in.memory_page_io_io_bytes != PAGE_SIZE or
            after_fault_in.memory_page_io_eviction_enabled != 1)
        {
            ok = self.failBool("pressure fault page-in") and ok;
        }
        const fault_clear = self.ctx.dev.memoryVmPageStateProbe(fault_region.id, 0, page_io_count, r4os.abi.memory_vm_page_state_operation_clear_slot, 0, 0, 0, 0) orelse {
            ok = self.failBool("pressure fault page-in clear unavailable") and ok;
            return ok;
        };
        if (fault_clear.status != r4os.abi.memory_vm_page_state_status_ready or fault_clear.slot_bound_pages != 0) ok = self.failBool("pressure fault page-in clear") and ok;
        const fault_slot_release = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, fault_slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, fault_owner_id, fault_region.id, 0) orelse {
            ok = self.failBool("pressure fault page-in slot release unavailable") and ok;
            return ok;
        };
        if (fault_slot_release.status != r4os.abi.memory_backing_store_slot_status_released) ok = self.failBool("pressure fault page-in slot release") and ok;
        fault_slot_release_needed = false;
        if (self.ctx.sys.vmRelease(fault_region.id) != r4os.abi.vm_ok) {
            ok = self.failBool("pressure fault page-in release") and ok;
            return ok;
        }
        fault_region_release_needed = false;

        var evict_returned_frames: u64 = 0;
        var evict_page_outs: u64 = 0;
        var evict_fault_ins: u64 = 0;
        var evict_page: u64 = 0;
        const evict_pages: u64 = 4;
        const evict_bytes: u64 = evict_pages * PAGE_SIZE;
        const evict_len: usize = @intCast(evict_bytes);
        const evict_region = self.ctx.sys.vmReserve(evict_bytes, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse {
            ok = self.failBool("pressure eviction reserve unavailable") and ok;
            return ok;
        };
        var evict_region_release_needed = true;
        defer {
            if (evict_region_release_needed) _ = self.ctx.sys.vmRelease(evict_region.id);
        }
        if (self.ctx.sys.vmCommit(evict_region.id, 0, evict_bytes) != r4os.abi.vm_ok) {
            ok = self.failBool("pressure eviction commit") and ok;
            return ok;
        }
        const evict_ptr: [*]u8 = @ptrFromInt(evict_region.base);
        var evict_byte_index: usize = 0;
        while (evict_byte_index < evict_len) : (evict_byte_index += 1) {
            evict_ptr[evict_byte_index] = @truncate(evict_byte_index *% 13 +% 0x17);
        }
        _ = self.ctx.dev.memoryVmPageStateProbe(evict_region.id, 0, 1, r4os.abi.memory_vm_page_state_operation_mark_pinned, 0, 0, 0, 0) orelse {
            ok = self.failBool("pressure eviction pin unavailable") and ok;
            return ok;
        };
        const evict_pressure_before = self.ctx.dev.memoryPressure() orelse {
            ok = self.failBool("pressure eviction pressure unavailable") and ok;
            return ok;
        };
        const evict_before = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure eviction baseline unavailable") and ok;
            return ok;
        };
        if ((evict_pressure_before.flags & r4os.abi.memory_pressure_flag_vm_page_reclaim) == 0) ok = self.failBool("pressure eviction vm reclaim flag") and ok;

        const frame_bytes: u64 = if (evict_before.fs_cache_payload_frame_bytes == 0) PAGE_SIZE else evict_before.fs_cache_payload_frame_bytes;
        var evict_vm_returned_frames: u64 = 0;
        var evict_vm_page_outs: u64 = 0;
        var target_evicted = false;
        var evict_attempt: u32 = 0;
        while (evict_attempt < 32) : (evict_attempt += 1) {
            const current_perf = self.ctx.dev.performanceSummary() orelse {
                ok = self.failBool("pressure eviction current unavailable") and ok;
                return ok;
            };
            const fs_frames = (current_perf.fs_cache_pmm_reclaimable_bytes / frame_bytes) + 1;
            var requested_frames: u32 = if (fs_frames > 1024) 1024 else @intCast(fs_frames);
            if (requested_frames == 0) requested_frames = 1;
            const current = self.ctx.dev.memoryReclaimProbe(requested_frames) orelse {
                ok = self.failBool("pressure eviction reclaim unavailable") and ok;
                return ok;
            };
            evict_vm_returned_frames +|= current.vm_returned_frames;
            evict_vm_page_outs +|= current.vm_page_outs;
            // Other programs can have independently evictable pages.  A VM
            // return from that owner is progress, but it does not prove this
            // diagnostic region was exercised.  Stop only once our exact
            // region contains a nonresident, slot-bound page.
            const target_state = self.ctx.dev.memoryVmPageStateProbe(evict_region.id, 0, evict_pages, r4os.abi.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse {
                ok = self.failBool("pressure eviction target state unavailable") and ok;
                return ok;
            };
            if (target_state.nonresident_pages > 0 and target_state.slot_bound_pages > 0) {
                target_evicted = true;
                break;
            }
        }
        if (!target_evicted) {
            ok = self.failBool("pressure eviction reclaim") and ok;
            return ok;
        }
        const evict_after = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure eviction summary unavailable") and ok;
            return ok;
        };
        const evict_state = self.ctx.dev.memoryVmPageStateProbe(evict_region.id, 0, evict_pages, r4os.abi.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse {
            ok = self.failBool("pressure eviction state unavailable") and ok;
            return ok;
        };
        var evict_page_index: u64 = 1;
        var evicted_page_found = false;
        while (evict_page_index < evict_pages) : (evict_page_index += 1) {
            const one_page = self.ctx.dev.memoryVmPageStateProbe(evict_region.id, evict_page_index * PAGE_SIZE, 1, r4os.abi.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse {
                ok = self.failBool("pressure eviction page state unavailable") and ok;
                return ok;
            };
            if (one_page.status == r4os.abi.memory_vm_page_state_status_ready and
                one_page.nonresident_pages == 1 and
                one_page.slot_bound_pages == 1)
            {
                evict_page = evict_page_index;
                evicted_page_found = true;
                break;
            }
        }
        const evict_before_fault = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure eviction fault baseline unavailable") and ok;
            return ok;
        };
        const evict_fault_index: usize = @intCast(evict_page * PAGE_SIZE + 19);
        const evict_fault_byte = if (evicted_page_found) evict_ptr[evict_fault_index] else 0;
        const evict_after_fault = self.ctx.dev.performanceSummary() orelse {
            ok = self.failBool("pressure eviction fault summary unavailable") and ok;
            return ok;
        };
        const evict_expected_byte: u8 = @truncate(evict_fault_index *% 13 +% 0x17);
        if (evict_vm_returned_frames == 0 or
            evict_vm_page_outs == 0 or
            evict_after.global_reclaim_vm_returned_frames < evict_before.global_reclaim_vm_returned_frames + evict_vm_returned_frames or
            evict_after.memory_vm_eviction_returned_frames < evict_before.memory_vm_eviction_returned_frames + evict_vm_returned_frames or
            evict_state.status != r4os.abi.memory_vm_page_state_status_ready or
            evict_state.pinned_pages != 1 or
            evict_state.nonresident_pages == 0 or
            !evicted_page_found or
            evict_fault_byte != evict_expected_byte or
            evict_after_fault.memory_vm_page_state_fault_page_in_count <= evict_before_fault.memory_vm_page_state_fault_page_in_count or
            evict_after_fault.memory_page_io_status != r4os.abi.memory_page_io_status_page_in_ok or
            evict_after_fault.memory_page_io_eviction_enabled != 1)
        {
            ok = self.failBool("pressure eviction reclaim") and ok;
        }
        evict_returned_frames = evict_vm_returned_frames;
        evict_page_outs = evict_vm_page_outs;
        evict_fault_ins = evict_after_fault.memory_vm_page_state_fault_page_in_count;
        if (self.ctx.sys.vmRelease(evict_region.id) != r4os.abi.vm_ok) {
            ok = self.failBool("pressure eviction release") and ok;
            return ok;
        }
        evict_region_release_needed = false;

        if (self.ctx.sys.vmRelease(gate_region.id) != r4os.abi.vm_ok) {
            ok = self.failBool("pressure gate release") and ok;
            return ok;
        }
        gate_release_needed = false;

        self.ctx.sys.write("MEMSUITE pressure: level=");
        self.ctx.sys.printU64(p.pressure_level);
        self.ctx.sys.write(" freeMB=");
        self.ctx.sys.printU64(p.free_physical_bytes / MB);
        self.ctx.sys.write(" appAvailMB=");
        self.ctx.sys.printU64(p.app_available_bytes / MB);
        self.ctx.sys.write(" committedMB=");
        self.ctx.sys.printU64(p.virtual_committed_bytes / MB);
        self.ctx.sys.write(" residentMB=");
        self.ctx.sys.printU64(p.virtual_resident_bytes / MB);
        self.ctx.sys.write(" headroomMB=");
        self.ctx.sys.printU64(p.commit_headroom_bytes / MB);
        self.ctx.sys.write(" reclaimable=");
        self.ctx.sys.printU64(p.reclaimable_bytes);
        self.ctx.sys.write(" dirty=");
        self.ctx.sys.printU64(p.dirty_bytes);
        self.ctx.sys.write(" fsClean=");
        self.ctx.sys.printU64(perf.fs_cache_clean_reclaimable_bytes);
        self.ctx.sys.write(" fsDirty=");
        self.ctx.sys.printU64(perf.fs_cache_dirty_non_reclaimable_bytes);
        self.ctx.sys.write(" pmmReclaim=");
        self.ctx.sys.printU64(perf.fs_cache_pmm_reclaimable_bytes);
        self.ctx.sys.write(" payloadFrames=");
        self.ctx.sys.printU64(perf.fs_cache_payload_frames);
        self.ctx.sys.write(" reclaimDrop=");
        self.ctx.sys.printU64(perf.fs_cache_reclaim_clean_entries);
        self.ctx.sys.write(" pagefileReady=");
        self.ctx.sys.printU64(perf.fs_cache_pagefile_ready);
        self.ctx.sys.write(" blockers=");
        self.ctx.sys.printU64(perf.fs_cache_pagefile_blockers);
        self.ctx.sys.write(" globalReclaim=");
        self.ctx.sys.printU64(reclaim_probe.returned_frames);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(reclaim_probe.returned_bytes);
        self.ctx.sys.write(" attempts=");
        self.ctx.sys.printU64(perf_after.global_reclaim_attempts);
        self.ctx.sys.write(" backing=");
        self.ctx.sys.printU64(backing.available_bytes);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(backing.requested_bytes);
        self.ctx.sys.write(" slots=");
        self.ctx.sys.printU64(slot_final.free_slots);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(slot_final.capacity_slots);
        self.ctx.sys.write(" gate=");
        self.ctx.sys.printU64(gate_ready.prepared_slots);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(gate_ready.capacity_slots);
        self.ctx.sys.write(" rollback=");
        self.ctx.sys.printU64(gate_ready.rollback_completed);
        self.ctx.sys.write(" pageIO=");
        self.ctx.sys.printU64(page_in.total_page_outs);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(page_in.total_page_ins);
        self.ctx.sys.write(" faultIn=");
        self.ctx.sys.printU64(after_fault_in.memory_vm_page_state_fault_page_in_count);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(after_fault_in.memory_vm_page_state_page_out_nonresident_pages);
        self.ctx.sys.write(" evict=");
        self.ctx.sys.printU64(evict_returned_frames);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(evict_page_outs);
        self.ctx.sys.write("@");
        self.ctx.sys.printU64(evict_page);
        self.ctx.sys.write(" evictFault=");
        self.ctx.sys.printU64(evict_fault_ins);
        self.ctx.sys.write(" pager=");
        self.ctx.sys.printU64(backing.pager_enabled);
        self.ctx.sys.println("");
        if (ok) self.ctx.sys.println("MEMSUITE pressure result: OK");
        return ok;
    }

    fn writeBackingStoreFile(self: *App, path: [*:0]const u8, total_bytes: u64) bool {
        if (self.ctx.sys.fileStreamBegin(path, r4os.abi.file_stream_open_replace) != r4os.abi.file_stream_result_ok) return false;
        var chunk: [4096]u8 = undefined;
        var i: usize = 0;
        while (i < chunk.len) : (i += 1) {
            chunk[i] = @as(u8, @truncate(i *% 11 +% 0x33));
        }
        var offset: u64 = 0;
        while (offset < total_bytes) {
            const remaining = total_bytes - offset;
            const len: usize = if (remaining > chunk.len) chunk.len else @intCast(remaining);
            const written = self.ctx.sys.fileStreamWrite(path, offset, chunk[0..len], 0);
            if (written != @as(i32, @intCast(len))) {
                _ = self.ctx.sys.fileStreamAbort(path);
                return false;
            }
            offset += @intCast(len);
        }
        return self.ctx.sys.fileStreamFinish(path, total_bytes, 0) == r4os.abi.file_stream_result_ok;
    }

    fn testPagerStressProfile(self: *App) bool {
        self.ctx.sys.println("MEMSUITE pagerstress");
        const current = self.currentMemoryInfo() orelse return self.failBool("pagerstress current owner unavailable");
        const owner_id = current.id;
        const before_totals = self.resourceTotalsForOwner(owner_id);
        const before_perf = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress baseline unavailable");
        var stats: PagerStressStats = .{};
        var ok = true;

        if (!self.writeBackingStoreFile(backing_store_path, backing_store_bytes)) return self.failBool("pagerstress backing create");
        ok = self.testPagerSmallRegionSweep(&stats) and ok;

        var cycle: u32 = 0;
        while (cycle < pager_stress_cycles) : (cycle += 1) {
            ok = self.testPagerStressCycle(cycle, &stats) and ok;
        }

        var kill_stats = VmStressStats{
            .table_before = self.resourceTotals().blocks,
            .table_during = self.resourceTotals().blocks,
        };
        ok = self.testKillCommittedVm(&kill_stats) and ok;

        const after_perf = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress summary unavailable");
        stats.storage_completion_max_ticks_before = before_perf.storage_completion_max_ticks;
        stats.fs_max_ticks_before = before_perf.fs_max_ticks;
        stats.reclaim_max_ticks_before = before_perf.global_reclaim_max_ticks;
        stats.storage_completion_max_ticks = after_perf.storage_completion_max_ticks;
        stats.fs_max_ticks = after_perf.fs_max_ticks;
        stats.reclaim_max_ticks = after_perf.global_reclaim_max_ticks;
        stats.storage_worker_requests = deltaU64(after_perf.storage_worker_runtime_requests, before_perf.storage_worker_runtime_requests);
        stats.storage_worker_completions = deltaU64(after_perf.storage_worker_runtime_completions, before_perf.storage_worker_runtime_completions);
        stats.storage_completion_signals = deltaU64(after_perf.storage_completion_signals, before_perf.storage_completion_signals);
        stats.storage_completion_timeouts = deltaU64(after_perf.storage_completion_timeouts, before_perf.storage_completion_timeouts);
        stats.fs_lock_timeouts = deltaU64(after_perf.fs_lock_timeouts, before_perf.fs_lock_timeouts);
        stats.service_completion_timeouts = deltaU64(after_perf.service_completion_timeouts, before_perf.service_completion_timeouts);
        stats.long_running_warnings = deltaU64(after_perf.long_running_task_warnings, before_perf.long_running_task_warnings);
        stats.starvation_warnings = deltaU64(after_perf.starvation_warnings, before_perf.starvation_warnings);
        stats.lock_contention_timeouts = deltaU64(after_perf.lock_contention_timeouts, before_perf.lock_contention_timeouts);
        stats.lock_sleep_under_lock = deltaU64(after_perf.lock_sleep_under_lock, before_perf.lock_sleep_under_lock);
        stats.lock_sleep_under_no_sleep_lock = deltaU64(after_perf.lock_sleep_under_no_sleep_lock, before_perf.lock_sleep_under_no_sleep_lock);
        stats.service_queue_high_water = after_perf.service_queue_high_water_total;
        stats.data_lost = after_perf.memory_page_io_data_lost_pages + after_perf.memory_vm_pager_data_lost_pages;

        const counter_ok = after_perf.memory_page_io_page_out_count > before_perf.memory_page_io_page_out_count and
            after_perf.memory_page_io_page_in_count > before_perf.memory_page_io_page_in_count and
            after_perf.memory_page_io_retryable_failure_count > before_perf.memory_page_io_retryable_failure_count and
            after_perf.memory_page_io_permanent_failure_count > before_perf.memory_page_io_permanent_failure_count and
            after_perf.memory_page_io_data_preserved_pages > before_perf.memory_page_io_data_preserved_pages and
            after_perf.memory_vm_eviction_page_out_count > before_perf.memory_vm_eviction_page_out_count and
            after_perf.memory_vm_eviction_returned_frames > before_perf.memory_vm_eviction_returned_frames and
            after_perf.memory_page_io_data_lost_pages == 0 and
            after_perf.memory_vm_pager_data_lost_pages == 0;
        if (!counter_ok) ok = self.failBool("pagerstress counters") and ok;

        const storage_worker_ok = after_perf.storage_worker_started != 0 and
            (after_perf.flags & r4os.abi.performance_flag_storage_driver_completion_ready) != 0 and
            stats.storage_worker_requests > 0 and
            stats.storage_worker_completions >= stats.storage_worker_requests and
            stats.storage_completion_signals >= stats.storage_worker_requests;
        if (!storage_worker_ok) ok = self.failBool("pagerstress storage worker") and ok;

        // Seit 0.61.10 wird jede Bedingung EINZELN geprueft und benannt.
        // Vorher kollabierten alle auf die eine Meldung "pagerstress
        // responsiveness", ohne Ist- oder Sollwert - ein Fehlschlag war damit
        // nicht auswertbar, und genau deshalb blieb er monatelang offen.
        var responsiveness_ok = true;
        responsiveness_ok = self.checkZero("storage completion timeouts", stats.storage_completion_timeouts) and responsiveness_ok;
        responsiveness_ok = self.checkZero("fs lock timeouts", stats.fs_lock_timeouts) and responsiveness_ok;
        responsiveness_ok = self.checkZero("long running warnings", stats.long_running_warnings) and responsiveness_ok;
        responsiveness_ok = self.checkZero("starvation warnings", stats.starvation_warnings) and responsiveness_ok;
        responsiveness_ok = self.checkZero("lock contention timeouts", stats.lock_contention_timeouts) and responsiveness_ok;
        responsiveness_ok = self.checkZero("lock sleep under lock", stats.lock_sleep_under_lock) and responsiveness_ok;
        responsiveness_ok = self.checkZero("lock sleep under no-sleep lock", stats.lock_sleep_under_no_sleep_lock) and responsiveness_ok;
        responsiveness_ok = self.checkLimit(
            "service queue high water",
            after_perf.service_queue_high_water_total,
            pager_stress_max_service_queue_high_water,
        ) and responsiveness_ok;
        responsiveness_ok = self.checkWindowMax(
            "storage completion",
            before_perf.storage_completion_max_ticks,
            after_perf.storage_completion_max_ticks,
            self.ctx.sys.ticksFromMilliseconds(pager_stress_max_storage_completion_ms),
        ) and responsiveness_ok;
        responsiveness_ok = self.checkWindowMax(
            "fs",
            before_perf.fs_max_ticks,
            after_perf.fs_max_ticks,
            self.ctx.sys.ticksFromMilliseconds(pager_stress_max_fs_ms),
        ) and responsiveness_ok;
        responsiveness_ok = self.checkWindowMax(
            "reclaim",
            before_perf.global_reclaim_max_ticks,
            after_perf.global_reclaim_max_ticks,
            self.ctx.sys.ticksFromMilliseconds(pager_stress_max_reclaim_ms),
        ) and responsiveness_ok;
        // service_completion_timeouts wird BERICHTET, faellt den Test aber
        // nicht mehr. Der Zaehler ist eine Summe ueber ALLE Endpoints des
        // Systems (services.zig:354) und waechst, sobald irgendein Aufrufer
        // sein selbst gewaehltes endliches Timeout ausschoepft - fuer viele
        // Aufrufer normaler Kontrollfluss. Ein fremder Hintergrunddienst ist
        // kein Urteil ueber den Pager.
        if (stats.service_completion_timeouts != 0) {
            self.ctx.sys.write("MEMSUITE pagerstress note: system-wide service completion timeouts during run=");
            self.ctx.sys.printU64(stats.service_completion_timeouts);
            self.ctx.sys.println(" (not attributed to pagerstress)");
        }
        if (!responsiveness_ok) ok = false;

        const after_totals = self.resourceTotalsForOwner(owner_id);
        stats.cleanup_ok = sameTotals(before_totals, after_totals);
        if (!stats.cleanup_ok) {
            self.printTotals("pagerstress-before", before_totals);
            self.printTotals("pagerstress-after", after_totals);
            ok = self.failBool("pagerstress cleanup mismatch") and ok;
        }

        self.printPagerStressStats(stats);
        if (ok) self.ctx.sys.println("MEMSUITE pagerstress result: OK");
        return ok;
    }

    fn testPagerSmallRegionSweep(self: *App, stats: *PagerStressStats) bool {
        self.ctx.sys.println("MEMSUITE pagerstress small regions");
        const current = self.currentMemoryInfo() orelse return self.failBool("pagerstress small owner unavailable");
        const before = self.resourceTotalsForOwner(current.id);
        var ids: [pager_stress_small_regions]u32 = .{0} ** pager_stress_small_regions;
        var i: usize = 0;
        while (i < ids.len) : (i += 1) {
            const info = self.ctx.sys.vmReserve(2 * PAGE_SIZE, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse {
                self.releaseIds(ids[0..]);
                return self.failBool("pagerstress small reserve");
            };
            ids[i] = info.id;
            if (self.ctx.sys.vmCommit(info.id, 0, PAGE_SIZE) != r4os.abi.vm_ok) {
                self.releaseIds(ids[0..]);
                return self.failBool("pagerstress small commit");
            }
            const ptr: [*]u8 = @ptrFromInt(info.base);
            ptr[0] = @as(u8, @truncate(i + 0x31));
            ptr[PAGE_SIZE - 1] = @as(u8, @truncate(i + 0x51));
            stats.small_regions += 1;
        }

        self.releaseIds(ids[0..]);
        const after = self.resourceTotalsForOwner(current.id);
        if (!sameTotals(before, after)) {
            self.printTotals("pager-small-before", before);
            self.printTotals("pager-small-after", after);
            return self.failBool("pagerstress small cleanup");
        }
        return true;
    }

    fn testPagerStressCycle(self: *App, cycle: u32, stats: *PagerStressStats) bool {
        self.ctx.sys.write("MEMSUITE pagerstress cycle ");
        self.ctx.sys.printU64(@as(u64, cycle) + 1);
        self.ctx.sys.println("");

        const region_bytes = pager_stress_region_pages * PAGE_SIZE;
        const io_bytes = pager_stress_io_pages * PAGE_SIZE;
        const region_len: usize = @intCast(region_bytes);
        const io_len: usize = @intCast(io_bytes);
        const page_len: usize = @intCast(PAGE_SIZE);

        const region = self.ctx.sys.vmReserve(region_bytes, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse return self.failBool("pagerstress reserve");
        var region_release_needed = true;
        defer {
            if (region_release_needed) _ = self.ctx.sys.vmRelease(region.id);
        }
        if (self.ctx.sys.vmCommit(region.id, 0, region_bytes) != r4os.abi.vm_ok) return self.failBool("pagerstress commit");
        const info = self.ctx.sys.vmQuery(region.id) orelse return self.failBool("pagerstress query");
        if (info.owner_id > 0xFFFF_FFFF) return self.failBool("pagerstress owner");
        const owner_id: u32 = @intCast(info.owner_id);
        const ptr: [*]u8 = @ptrFromInt(info.base);

        var byte_index: usize = 0;
        while (byte_index < region_len) : (byte_index += 1) {
            ptr[byte_index] = pagerStressPattern(cycle, byte_index);
        }

        const slot = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_reserve, pager_stress_io_pages, 0, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, region.id, 0) orelse return self.failBool("pagerstress slot reserve unavailable");
        var slot_release_needed = true;
        defer {
            if (slot_release_needed) _ = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, region.id, 0);
        }
        if (slot.status != r4os.abi.memory_backing_store_slot_status_reserved or slot.reservation_id == 0) return self.failBool("pagerstress slot reserve");

        const page_out = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, region.id, 0, slot.reservation_id, 0, pager_stress_io_pages, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, slot.generation, ptr[0..io_len], 0) orelse return self.failBool("pagerstress page out unavailable");
        if (page_out.status != r4os.abi.memory_page_io_status_page_out_ok or !pageIoFlagsOk(page_out.flags, r4os.abi.memory_page_io_operation_page_out)) {
            self.printPageIoProbe("pagerstress page out", page_out);
            return self.failBool("pagerstress page out");
        }
        stats.page_outs += pager_stress_io_pages;

        var page: u64 = 0;
        const before_fault = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress fault baseline");
        while (page < pager_stress_io_pages) : (page += 1) {
            const offset: usize = @intCast(page * PAGE_SIZE);
            if (ptr[offset] != pagerStressPattern(cycle, offset)) return self.failBool("pagerstress explicit fault data");
            if (ptr[offset + 19] != pagerStressPattern(cycle, offset + 19)) return self.failBool("pagerstress explicit fault tail");
        }
        const after_fault = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress fault summary");
        if (after_fault.memory_page_io_page_in_count < before_fault.memory_page_io_page_in_count + pager_stress_io_pages) return self.failBool("pagerstress explicit fault counters");
        stats.fault_ins += after_fault.memory_page_io_page_in_count - before_fault.memory_page_io_page_in_count;

        const page_missing = self.ctx.dev.memoryPageIoProbe(missing_backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, region.id, 0, slot.reservation_id, 0, 1, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, page_out.slot_generation, ptr[0..page_len], r4os.abi.memory_page_io_flag_retry_request) orelse return self.failBool("pagerstress missing page io unavailable");
        if (page_missing.status != r4os.abi.memory_page_io_status_backing_unavailable or
            (page_missing.flags & r4os.abi.memory_page_io_flag_retryable_failure) == 0 or
            (page_missing.flags & r4os.abi.memory_page_io_flag_data_preserved) == 0)
        {
            return self.failBool("pagerstress retryable failure");
        }
        stats.retryable_failures += 1;
        stats.data_preserved += 1;

        const page_mark = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_mark_error, 0, slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, region.id, 0) orelse return self.failBool("pagerstress slot mark unavailable");
        const page_error = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, region.id, 0, slot.reservation_id, 0, 1, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, page_mark.generation, ptr[0..page_len], r4os.abi.memory_page_io_flag_retry_request) orelse return self.failBool("pagerstress permanent page io unavailable");
        if (page_mark.status != r4os.abi.memory_backing_store_slot_status_error_marked or
            page_error.status != r4os.abi.memory_page_io_status_slot_error or
            (page_error.flags & r4os.abi.memory_page_io_flag_permanent_failure) == 0)
        {
            return self.failBool("pagerstress permanent failure");
        }
        stats.permanent_failures += 1;

        const page_recover = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_recover, 0, slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, region.id, 0) orelse return self.failBool("pagerstress slot recover unavailable");
        if (page_recover.status != r4os.abi.memory_backing_store_slot_status_recovered) return self.failBool("pagerstress slot recover");

        const page_retry = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, region.id, 0, slot.reservation_id, 0, pager_stress_io_pages, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, page_recover.generation, ptr[0..io_len], r4os.abi.memory_page_io_flag_retry_request) orelse return self.failBool("pagerstress retry page out unavailable");
        if (page_retry.status != r4os.abi.memory_page_io_status_page_out_ok or !pageIoFlagsOk(page_retry.flags, r4os.abi.memory_page_io_operation_page_out)) {
            self.printPageIoProbe("pagerstress retry page out", page_retry);
            return self.failBool("pagerstress retry page out");
        }
        stats.page_outs += pager_stress_io_pages;

        const before_retry_in = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress retry page in baseline");
        const page_retry_in = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_in, region.id, 0, slot.reservation_id, 0, pager_stress_io_pages, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, page_retry.slot_generation, ptr[0..io_len], 0) orelse return self.failBool("pagerstress retry page in unavailable");
        const after_retry_in = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress retry page in summary");
        if (page_retry_in.status != r4os.abi.memory_page_io_status_page_in_ok or
            !pageIoFlagsOk(page_retry_in.flags, r4os.abi.memory_page_io_operation_page_in) or
            after_retry_in.memory_page_io_page_in_count < before_retry_in.memory_page_io_page_in_count + pager_stress_io_pages)
        {
            return self.failBool("pagerstress retry page in");
        }
        stats.fault_ins += after_retry_in.memory_page_io_page_in_count - before_retry_in.memory_page_io_page_in_count;

        const before_reclaim = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress reclaim baseline");
        const frame_bytes: u64 = if (before_reclaim.fs_cache_payload_frame_bytes == 0) PAGE_SIZE else before_reclaim.fs_cache_payload_frame_bytes;
        var reclaim_frames: u64 = 0;
        var reclaim_page_outs: u64 = 0;
        var reclaimed_page: ?u64 = null;
        var attempts: u32 = 0;
        while (attempts < 32) : (attempts += 1) {
            const current_perf = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress reclaim current");
            const fs_frames = (current_perf.fs_cache_pmm_reclaimable_bytes / frame_bytes) + 1;
            var requested_frames: u32 = if (fs_frames > 1024) 1024 else @intCast(fs_frames);
            if (requested_frames == 0) requested_frames = 1;
            const current = self.ctx.dev.memoryReclaimProbe(requested_frames) orelse return self.failBool("pagerstress reclaim probe unavailable");
            reclaim_frames +|= current.vm_returned_frames;
            reclaim_page_outs +|= current.vm_page_outs;
            reclaimed_page = self.findNonresidentPageFrom(region.id, pager_stress_io_pages, pager_stress_region_pages) orelse
                self.findNonresidentPage(region.id, pager_stress_region_pages);
            if (reclaimed_page != null) break;
        }
        if (reclaim_frames == 0 or reclaim_page_outs == 0) return self.failBool("pagerstress reclaim vm");
        stats.reclaim_frames += reclaim_frames;
        stats.page_outs += reclaim_page_outs;

        // 0.61.14: Der globale Reclaimer hat oben nachweislich VM-Seiten
        // ausgelagert (reclaim vm), darf als Opfer aber legitim ANDERE
        // Owner waehlen - seit 0.61.13 laufen mehr Programme vor diesem
        // Test, womit die stille Annahme, der globale Lauf treffe genau
        // diese Region, zuverlaessig kippte. Historische Flake-Ursache,
        // erstmals benannt im gesicherten Log: pagerstress reclaim
        // nonresident. Fuer den Fault-in-Teil wird deshalb bei Bedarf
        // DETERMINISTISCH eine eigene Seite ausgelagert; der globale
        // Nachweis bleibt unveraendert die reclaim-vm-Bedingung.
        if (reclaimed_page == null) {
            const forced_out = self.ctx.dev.memoryPageIoProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_page_io_operation_page_out, region.id, 0, slot.reservation_id, 0, 1, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, page_retry_in.slot_generation, ptr[0..page_len], 0) orelse return self.failBool("pagerstress forced page out unavailable");
            if (forced_out.status != r4os.abi.memory_page_io_status_page_out_ok) {
                self.printPageIoProbe("pagerstress forced page out", forced_out);
                return self.failBool("pagerstress forced page out");
            }
            stats.page_outs += 1;
            reclaimed_page = self.findNonresidentPage(region.id, pager_stress_region_pages);
        }

        const fault_page = reclaimed_page orelse return self.failBool("pagerstress reclaim nonresident");
        const reclaim_fault_offset: usize = @intCast(fault_page * PAGE_SIZE + 23);
        const before_reclaim_fault = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress reclaim fault baseline");
        if (ptr[reclaim_fault_offset] != pagerStressPattern(cycle, reclaim_fault_offset)) return self.failBool("pagerstress reclaim fault data");
        const after_reclaim_fault = self.ctx.dev.performanceSummary() orelse return self.failBool("pagerstress reclaim fault summary");
        if (after_reclaim_fault.memory_page_io_page_in_count <= before_reclaim_fault.memory_page_io_page_in_count or
            after_reclaim_fault.memory_page_io_status != r4os.abi.memory_page_io_status_page_in_ok)
        {
            return self.failBool("pagerstress reclaim fault counters");
        }
        stats.fault_ins += after_reclaim_fault.memory_page_io_page_in_count - before_reclaim_fault.memory_page_io_page_in_count;

        page = 0;
        while (page < pager_stress_io_pages) : (page += 1) {
            const offset: usize = @intCast(page * PAGE_SIZE);
            if (ptr[offset] != pagerStressPattern(cycle, offset)) return self.failBool("pagerstress cleanup fault data");
        }

        const clear = self.ctx.dev.memoryVmPageStateProbe(region.id, 0, pager_stress_io_pages, r4os.abi.memory_vm_page_state_operation_clear_slot, 0, 0, 0, 0) orelse return self.failBool("pagerstress clear unavailable");
        if (clear.status != r4os.abi.memory_vm_page_state_status_ready or clear.slot_bound_pages != 0) return self.failBool("pagerstress clear");
        const release = self.ctx.dev.memoryBackingStoreSlotProbe(backing_store_path, backing_store_bytes, r4os.abi.memory_backing_store_slot_operation_release, 0, slot.reservation_id, r4os.abi.memory_backing_store_slot_owner_kind_vm_region, owner_id, region.id, 0) orelse return self.failBool("pagerstress slot release unavailable");
        if (release.status != r4os.abi.memory_backing_store_slot_status_released) return self.failBool("pagerstress slot release");
        slot_release_needed = false;

        if (self.ctx.sys.vmRelease(region.id) != r4os.abi.vm_ok) return self.failBool("pagerstress release");
        region_release_needed = false;
        stats.cycles += 1;
        return true;
    }

    fn findNonresidentPage(self: *App, region_id: u32, page_count: u64) ?u64 {
        return self.findNonresidentPageFrom(region_id, 0, page_count);
    }

    fn findNonresidentPageFrom(self: *App, region_id: u32, first_page: u64, page_count: u64) ?u64 {
        var page: u64 = 0;
        while (first_page + page < page_count) : (page += 1) {
            const page_index = first_page + page;
            const state = self.ctx.dev.memoryVmPageStateProbe(region_id, page_index * PAGE_SIZE, 1, r4os.abi.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse return null;
            if (state.status == r4os.abi.memory_vm_page_state_status_ready and state.nonresident_pages == 1 and state.slot_bound_pages == 1) return page_index;
        }
        return null;
    }

    fn printPagerStressStats(self: *App, stats: PagerStressStats) void {
        self.ctx.sys.write("MEMSUITE pagerstress: cycles=");
        self.ctx.sys.printU64(stats.cycles);
        self.ctx.sys.write(" smallRegions=");
        self.ctx.sys.printU64(stats.small_regions);
        self.ctx.sys.write(" pageOuts=");
        self.ctx.sys.printU64(stats.page_outs);
        self.ctx.sys.write(" faultIns=");
        self.ctx.sys.printU64(stats.fault_ins);
        self.ctx.sys.write(" reclaimFrames=");
        self.ctx.sys.printU64(stats.reclaim_frames);
        self.ctx.sys.write(" retryable=");
        self.ctx.sys.printU64(stats.retryable_failures);
        self.ctx.sys.write(" permanent=");
        self.ctx.sys.printU64(stats.permanent_failures);
        self.ctx.sys.write(" preserved=");
        self.ctx.sys.printU64(stats.data_preserved);
        self.ctx.sys.write(" lost=");
        self.ctx.sys.printU64(stats.data_lost);
        // Seit 0.61.10 als vorher-nachher, weil die Werte seit dem BOOT
        // laufen. Ein hoher Vorher-Wert stammt nicht aus diesem Lauf.
        self.ctx.sys.write(" maxTicks storage/fs/reclaim=");
        self.ctx.sys.printU64(stats.storage_completion_max_ticks_before);
        self.ctx.sys.write("->");
        self.ctx.sys.printU64(stats.storage_completion_max_ticks);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.fs_max_ticks_before);
        self.ctx.sys.write("->");
        self.ctx.sys.printU64(stats.fs_max_ticks);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.reclaim_max_ticks_before);
        self.ctx.sys.write("->");
        self.ctx.sys.printU64(stats.reclaim_max_ticks);
        self.ctx.sys.write(" worker=");
        self.ctx.sys.printU64(stats.storage_worker_requests);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.storage_worker_completions);
        self.ctx.sys.write(" signals=");
        self.ctx.sys.printU64(stats.storage_completion_signals);
        self.ctx.sys.write(" timeouts storage/fs/service=");
        self.ctx.sys.printU64(stats.storage_completion_timeouts);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.fs_lock_timeouts);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.service_completion_timeouts);
        self.ctx.sys.write(" warn long/starve=");
        self.ctx.sys.printU64(stats.long_running_warnings);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.starvation_warnings);
        self.ctx.sys.write(" lock timeout/sleep/noSleep=");
        self.ctx.sys.printU64(stats.lock_contention_timeouts);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.lock_sleep_under_lock);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.lock_sleep_under_no_sleep_lock);
        self.ctx.sys.write(" serviceQ=");
        self.ctx.sys.printU64(stats.service_queue_high_water);
        self.ctx.sys.write(" ownerCleanup=");
        self.ctx.sys.println(if (stats.cleanup_ok) "OK" else "FAILED");
    }

    fn printPageIoProbe(self: *App, label: []const u8, probe: r4os.abi.ProgramMemoryPageIoProbe) void {
        self.ctx.sys.write("MEMSUITE ");
        self.ctx.sys.write(label);
        self.ctx.sys.write(": status=");
        self.ctx.sys.printU64(probe.status);
        self.ctx.sys.write(" blockers=");
        self.ctx.sys.printU64(probe.blockers);
        self.ctx.sys.write(" flags=");
        self.ctx.sys.printU64(probe.flags);
        self.ctx.sys.write(" io=");
        printI32(self, probe.io_status);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(probe.io_bytes);
        self.ctx.sys.write(" transfer=");
        self.ctx.sys.printU64(probe.transfer_bytes);
        self.ctx.sys.write(" gen=");
        self.ctx.sys.printU64(probe.expected_generation);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(probe.slot_generation);
        self.ctx.sys.write(" slots cap/res/valid/err=");
        self.ctx.sys.printU64(probe.capacity_slots);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(probe.reserved_slots);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(probe.valid_slots);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(probe.error_slots);
        self.ctx.sys.write(" backing=");
        self.ctx.sys.printU64(probe.backing_slot);
        self.ctx.sys.write("@");
        self.ctx.sys.printU64(probe.backing_offset);
        self.ctx.sys.println("");
    }

    fn printI32(self: *App, value: i32) void {
        if (value < 0) {
            self.ctx.sys.write("-");
            self.ctx.sys.printU64(@as(u64, @intCast(-value)));
        } else {
            self.ctx.sys.printU64(@intCast(value));
        }
    }

    fn testMultiGbProfile(self: *App) bool {
        const profile = self.selectedMultiGbProfile();
        self.ctx.sys.write("MEMSUITE multigb profile=");
        self.ctx.sys.println(profile.name);

        const before = self.resourceTotals();
        var stats = VmStressStats{
            .table_before = before.blocks,
            .table_during = before.blocks,
        };

        const reserved = self.ctx.sys.vmReserve(profile.reserve_bytes, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse return self.failBool("multigb reserve");
        var release_needed = true;
        defer {
            if (release_needed) _ = self.ctx.sys.vmRelease(reserved.id);
        }
        stats.reserved_bytes = reserved.len;
        self.noteTableDuring(&stats);

        if (reserved.len < profile.reserve_bytes) return self.failBool("multigb reserve length");
        if (self.ctx.sys.vmCommit(reserved.id, 0, profile.commit_bytes) != r4os.abi.vm_ok) return self.failBool("multigb commit");
        stats.committed_bytes = profile.commit_bytes;

        const committed = self.ctx.sys.vmQuery(reserved.id) orelse return self.failBool("multigb query committed");
        if (committed.committed_bytes < profile.commit_bytes) return self.failBool("multigb committed bytes");
        if (committed.resident_bytes != 0 or committed.fault_count != 0 or committed.failed_faults != 0) return self.failBool("multigb pre-touch stats");

        const ptr: [*]u8 = @ptrFromInt(committed.base);
        stats.touched_pages = touchVmPages(ptr, profile.touch_bytes, 0x6D);

        const touched = self.ctx.sys.vmQuery(reserved.id) orelse return self.failBool("multigb query touched");
        const touched_bytes = stats.touched_pages * PAGE_SIZE;
        if (touched.resident_bytes < touched_bytes) return self.failBool("multigb resident bytes");
        if (touched.peak_resident_bytes < touched.resident_bytes) return self.failBool("multigb peak resident");
        if (touched.fault_count < stats.touched_pages) return self.failBool("multigb page faults");
        if (touched.failed_faults != 0) return self.failBool("multigb failed faults");
        stats.resident_bytes = touched.resident_bytes;
        stats.peak_resident_bytes = touched.peak_resident_bytes;
        stats.page_faults = touched.fault_count;
        stats.failed_faults = touched.failed_faults;

        if (self.ctx.sys.vmDecommit(reserved.id, 0, profile.commit_bytes) != r4os.abi.vm_ok) return self.failBool("multigb decommit");
        stats.decommits += 1;
        const decommitted = self.ctx.sys.vmQuery(reserved.id) orelse return self.failBool("multigb query decommitted");
        if (decommitted.committed_bytes != 0 or decommitted.resident_bytes != 0) return self.failBool("multigb decommit stats");
        if (self.ctx.sys.vmRelease(reserved.id) != r4os.abi.vm_ok) return self.failBool("multigb release");
        release_needed = false;

        const after = self.resourceTotals();
        stats.table_after = after.blocks;
        stats.cleanup_ok = sameTotals(before, after);
        self.printVmStressStats("multigb", stats);
        if (!stats.cleanup_ok) {
            self.printTotals("multigb-before", before);
            self.printTotals("multigb-after", after);
            return self.failBool("multigb cleanup mismatch");
        }

        self.ctx.sys.write("MEMSUITE multigb result: OK profile=");
        self.ctx.sys.write(profile.name);
        self.ctx.sys.write(" reserveMB=");
        self.ctx.sys.printU64(profile.reserve_bytes / MB);
        self.ctx.sys.write(" commitMB=");
        self.ctx.sys.printU64(profile.commit_bytes / MB);
        self.ctx.sys.write(" touchedMB=");
        self.ctx.sys.printU64(profile.touch_bytes / MB);
        self.ctx.sys.write(" residentMB=");
        self.ctx.sys.printU64(stats.resident_bytes / MB);
        self.ctx.sys.write(" faults=");
        self.ctx.sys.printU64(stats.page_faults);
        self.ctx.sys.write(" failed=");
        self.ctx.sys.printU64(stats.failed_faults);
        self.ctx.sys.println("");
        return true;
    }

    fn selectedMultiGbProfile(self: *App) MultiGbProfile {
        const args = self.ctx.sys.argsRaw();
        if (argsContain(args, "/LARGE")) return .{ .name = "large", .reserve_bytes = 6 * GB, .commit_bytes = 512 * MB, .touch_bytes = 64 * MB };
        if (argsContain(args, "/NORMAL")) return .{ .name = "normal", .reserve_bytes = 4 * GB, .commit_bytes = 256 * MB, .touch_bytes = 32 * MB };
        return .{ .name = "small", .reserve_bytes = 2 * GB, .commit_bytes = 128 * MB, .touch_bytes = 16 * MB };
    }

    fn testVmReserveMatrix(self: *App, stats: *VmStressStats) bool {
        self.ctx.sys.println("MEMSUITE vm reserve matrix");
        const before = self.resourceTotals();
        var ids: [16]u32 = .{0} ** 16;
        var i: usize = 0;
        while (i < ids.len) : (i += 1) {
            const info = self.ctx.sys.vmReserve(8 * MB, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse {
                self.releaseIds(ids[0..]);
                return self.failBool("reserve matrix alloc");
            };
            ids[i] = info.id;
            stats.reserved_bytes +%= info.len;
            self.noteTableDuring(stats);
        }

        i = 1;
        while (i < ids.len) : (i += 2) {
            if (self.ctx.sys.vmRelease(ids[i]) != r4os.abi.vm_ok) {
                self.releaseIds(ids[0..]);
                return self.failBool("reserve matrix release gap");
            }
            ids[i] = 0;
        }

        const gap = self.ctx.sys.vmReserve(32 * MB, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse {
            self.releaseIds(ids[0..]);
            return self.failBool("reserve matrix gap alloc");
        };
        stats.reserved_bytes +%= gap.len;
        self.noteTableDuring(stats);
        if (self.ctx.sys.vmRelease(gap.id) != r4os.abi.vm_ok) {
            self.releaseIds(ids[0..]);
            return self.failBool("reserve matrix gap release");
        }

        self.releaseIds(ids[0..]);
        const after = self.resourceTotals();
        if (!sameTotals(before, after)) {
            self.printTotals("reserve-before", before);
            self.printTotals("reserve-after", after);
            return self.failBool("reserve matrix cleanup");
        }
        return true;
    }

    fn testDemandCommitStats(self: *App, stats: *VmStressStats, reserve_bytes: u64, commit_bytes: u64, touch_bytes: u64) bool {
        self.ctx.sys.println("MEMSUITE demand commit");
        if (touch_bytes > commit_bytes) return self.failBool("demand profile invalid");
        const before = self.resourceTotals();
        const reserved = self.ctx.sys.vmReserve(reserve_bytes, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse return self.failBool("demand reserve");
        var release_needed = true;
        defer {
            if (release_needed) _ = self.ctx.sys.vmRelease(reserved.id);
        }
        stats.reserved_bytes +%= reserved.len;
        self.noteTableDuring(stats);

        if (self.ctx.sys.vmCommit(reserved.id, 0, commit_bytes) != r4os.abi.vm_ok) return self.failBool("demand commit");
        stats.committed_bytes +%= commit_bytes;
        const committed = self.ctx.sys.vmQuery(reserved.id) orelse return self.failBool("demand query committed");
        if (committed.committed_bytes < commit_bytes) return self.failBool("demand committed bytes");
        if (committed.resident_bytes != 0 or committed.fault_count != 0 or committed.failed_faults != 0) return self.failBool("demand pre-touch stats");

        const ptr: [*]u8 = @ptrFromInt(committed.base);
        const touched_pages = touchVmPages(ptr, touch_bytes, 0x85);
        stats.touched_pages +%= touched_pages;

        const touched = self.ctx.sys.vmQuery(reserved.id) orelse return self.failBool("demand query touched");
        const touched_bytes = touched_pages * PAGE_SIZE;
        if (touched.resident_bytes < touched_bytes) return self.failBool("demand resident bytes");
        if (touched.peak_resident_bytes < touched.resident_bytes) return self.failBool("demand peak resident");
        if (touched.fault_count < touched_pages) return self.failBool("demand page faults");
        if (touched.failed_faults != 0) return self.failBool("demand failed faults");
        stats.resident_bytes +%= touched.resident_bytes;
        if (touched.peak_resident_bytes > stats.peak_resident_bytes) stats.peak_resident_bytes = touched.peak_resident_bytes;
        stats.page_faults +%= touched.fault_count;
        stats.failed_faults +%= touched.failed_faults;

        if (self.ctx.sys.vmDecommit(reserved.id, 0, commit_bytes) != r4os.abi.vm_ok) return self.failBool("demand decommit");
        stats.decommits += 1;
        const decommitted = self.ctx.sys.vmQuery(reserved.id) orelse return self.failBool("demand query decommitted");
        if (decommitted.committed_bytes != 0 or decommitted.resident_bytes != 0) return self.failBool("demand decommit stats");
        if (self.ctx.sys.vmRelease(reserved.id) != r4os.abi.vm_ok) return self.failBool("demand release");
        release_needed = false;

        const after = self.resourceTotals();
        if (!sameTotals(before, after)) {
            self.printTotals("demand-before", before);
            self.printTotals("demand-after", after);
            return self.failBool("demand cleanup");
        }
        return true;
    }

    fn testVmLimitAccounting(self: *App, stats: *VmStressStats) bool {
        self.ctx.sys.println("MEMSUITE vm limit accounting");
        const info = self.currentMemoryInfo() orelse return self.failBool("current memory profile missing");

        var out: r4os.abi.ProgramVmRegionInfo = .{};
        const reserve_code = self.ctx.sys.vmReserveRaw(info.memory_reserved_limit + PAGE_SIZE, PAGE_SIZE, r4os.abi.vm_region_flags_default, &out);
        if (reserve_code != r4os.abi.vm_error_limit_exceeded) return self.failBool("reserve limit code");
        stats.limit_errors += 1;

        const reserve_size = if (info.memory_committed_limit + PAGE_SIZE <= info.memory_reserved_limit)
            info.memory_committed_limit + PAGE_SIZE
        else
            info.memory_reserved_limit;
        const reserved = self.ctx.sys.vmReserve(reserve_size, PAGE_SIZE, r4os.abi.vm_region_flags_default) orelse return self.failBool("commit limit reserve");
        defer _ = self.ctx.sys.vmRelease(reserved.id);
        self.noteTableDuring(stats);
        const commit_code = self.ctx.sys.vmCommit(reserved.id, 0, info.memory_committed_limit + PAGE_SIZE);
        if (commit_code != r4os.abi.vm_error_limit_exceeded) return self.failBool("commit limit code");
        stats.limit_errors += 1;
        return true;
    }

    fn testKillCommittedVm(self: *App, stats: *VmStressStats) bool {
        self.ctx.sys.println("MEMSUITE kill holdvm");
        const before = self.resourceTotals();
        var process: r4os.abi.ProgramProcessHandle = .{};
        if (self.ctx.sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X", "/HOLDVM", .console, &process) != r4os.abi.program_handle_ok)
            return self.failBool("holdvm spawn");
        defer self.cleanupProgramHandle(&process, self.ctx.sys.ticksFromMilliseconds(program_lifecycle_timeout_ms));
        const id = process.instance_id;
        if (!self.waitOwnerCommitted(id, 16 * MB, 500)) {
            return self.failBool("holdvm resources not visible");
        }
        self.noteTableDuring(stats);
        if (self.ctx.sys.programHandleKill(&process) != r4os.abi.program_handle_ok) return self.failBool("holdvm kill");
        if (!self.waitAndReapProgramHandle(&process, self.ctx.sys.ticksFromMilliseconds(program_lifecycle_timeout_ms)))
            return self.failBool("holdvm killed instance active");
        if (self.ownerResourceBlocks(id) != 0) return self.failBool("holdvm owner still has blocks");
        self.ctx.sys.sleepTicks(2);

        const after = self.resourceTotals();
        if (!sameTotals(before, after)) {
            self.printTotals("holdvm-before", before);
            self.printTotals("holdvm-after", after);
            return self.failBool("holdvm cleanup mismatch");
        }
        stats.cleanup_ok = true;
        return true;
    }

    fn testLocalAllocator(self: *App) bool {
        self.ctx.sys.println("MEMSUITE local allocator");
        const before = self.ctx.sys.allocatorStats();

        if (!self.testRealloc()) return false;
        if (!self.testFragmentation()) return false;
        if (!self.testLargeContiguous()) return false;

        const after_free = self.ctx.sys.allocatorStats();
        if (after_free.active_bytes != before.active_bytes or after_free.active_allocations != before.active_allocations) {
            self.printAllocatorStats("before", before);
            self.printAllocatorStats("after", after_free);
            return self.failBool("local allocator leak");
        }

        self.ctx.sys.println("MEMSUITE local allocator: ok");
        return true;
    }

    fn testRealloc(self: *App) bool {
        const allocator = self.ctx.sys.allocator();
        var mem = allocator.alignedAlloc(u8, .fromByteUnits(16), 1024) catch return self.failBool("realloc initial alloc");
        mem[0] = 0x19;
        mem[1023] = 0x91;
        mem = allocator.realloc(mem, 64 * 1024) catch return self.failBool("realloc grow");
        if (mem[0] != 0x19 or mem[1023] != 0x91) return self.failBool("realloc copy");
        mem[4096] = 0x44;
        mem = allocator.realloc(mem, 2048) catch return self.failBool("realloc shrink");
        if (mem[0] != 0x19 or mem[1023] != 0x91) return self.failBool("realloc shrink copy");
        allocator.free(mem);
        return true;
    }

    fn testFragmentation(self: *App) bool {
        const allocator = self.ctx.sys.allocator();
        var chunks: [48]?[]u8 = .{null} ** 48;
        var i: usize = 0;
        while (i < chunks.len) : (i += 1) {
            const size = 512 + (i + 1) * 173;
            chunks[i] = allocator.alloc(u8, size) catch {
                self.freeChunks(allocator, chunks[0..]);
                return self.failBool("fragment alloc");
            };
            touch(chunks[i].?, @intCast(i));
        }

        i = 0;
        while (i < chunks.len) : (i += 2) {
            if (chunks[i]) |mem| {
                allocator.free(mem);
                chunks[i] = null;
            }
        }

        const middle = allocator.alignedAlloc(u8, .fromByteUnits(4096), 96 * 1024) catch {
            self.freeChunks(allocator, chunks[0..]);
            return self.failBool("fragment middle alloc");
        };
        touch(middle, 0xA5);
        allocator.free(middle);

        self.freeChunks(allocator, chunks[0..]);
        return true;
    }

    fn testLargeContiguous(self: *App) bool {
        const allocator = self.ctx.sys.allocator();
        const mem = allocator.alignedAlloc(u8, .fromByteUnits(4096), 4 * 1024 * 1024) catch return self.failBool("large alloc");
        touch(mem, 0x4D);
        allocator.free(mem);
        return true;
    }

    fn freeChunks(self: *App, allocator: std.mem.Allocator, chunks: []?[]u8) void {
        _ = self;
        var i: usize = 0;
        while (i < chunks.len) : (i += 1) {
            if (chunks[i]) |mem| {
                allocator.free(mem);
                chunks[i] = null;
            }
        }
    }

    fn testRepeatedProgramCleanup(self: *App, label: []const u8, path: [*:0]const u8, args: [*:0]const u8, cycles: u32) bool {
        self.ctx.sys.write("MEMSUITE repeated ");
        self.ctx.sys.write(label);
        self.ctx.sys.write(" x");
        self.ctx.sys.printU64(cycles);
        self.ctx.sys.println("");

        var cycle: u32 = 0;
        while (cycle < cycles) : (cycle += 1) {
            const before = self.resourceTotals();
            var process: r4os.abi.ProgramProcessHandle = .{};
            if (self.ctx.sys.programSpawnHandle(path, args, .console, &process) != r4os.abi.program_handle_ok)
                return self.failBool("spawn failed");
            const lifecycle_timeout = self.ctx.sys.ticksFromMilliseconds(program_lifecycle_timeout_ms);
            if (!self.waitAndReapProgramHandle(&process, lifecycle_timeout)) {
                self.cleanupProgramHandle(&process, lifecycle_timeout);
                return self.failBool("spawned instance still active");
            }
            self.ctx.sys.sleepTicks(2);
            var status: r4os.abi.ProgramStatus = .{};
            self.ctx.sys.programStatus(&status);
            if (status.last_exit_code != 0) return self.failBool("spawned instance exit code");
            const after = self.resourceTotals();
            if (!sameTotals(before, after)) {
                self.printTotals("before", before);
                self.printTotals("after", after);
                return self.failBool("spawn cleanup mismatch");
            }
        }
        return true;
    }

    fn testKillWhileHolding(self: *App) bool {
        self.ctx.sys.println("MEMSUITE kill hold x2");
        const before = self.resourceTotals();
        var first = self.spawnHold() orelse return false;
        defer self.cleanupProgramHandle(&first, self.ctx.sys.ticksFromMilliseconds(program_lifecycle_timeout_ms));
        var second = self.spawnHold() orelse return false;
        defer self.cleanupProgramHandle(&second, self.ctx.sys.ticksFromMilliseconds(program_lifecycle_timeout_ms));
        const first_id = first.instance_id;
        const second_id = second.instance_id;

        if (!self.waitOwnerResources(first_id, 500) or !self.waitOwnerResources(second_id, 500)) {
            return self.failBool("hold resources not visible");
        }
        if (self.ctx.sys.programHandleKill(&first) != r4os.abi.program_handle_ok) return self.failBool("kill first");
        if (self.ctx.sys.programHandleKill(&second) != r4os.abi.program_handle_ok) return self.failBool("kill second");
        const lifecycle_timeout = self.ctx.sys.ticksFromMilliseconds(program_lifecycle_timeout_ms);
        if (!self.waitAndReapProgramHandle(&first, lifecycle_timeout) or !self.waitAndReapProgramHandle(&second, lifecycle_timeout))
            return self.failBool("killed instance active");
        if (self.ownerResourceBlocks(first_id) != 0 or self.ownerResourceBlocks(second_id) != 0)
            return self.failBool("killed owner still has blocks");
        self.ctx.sys.sleepTicks(2);

        const after = self.resourceTotals();
        if (!sameTotals(before, after)) {
            self.printTotals("before", before);
            self.printTotals("after", after);
            return self.failBool("kill cleanup mismatch");
        }
        return true;
    }

    fn spawnHold(self: *App) ?r4os.abi.ProgramProcessHandle {
        var process: r4os.abi.ProgramProcessHandle = .{};
        if (self.ctx.sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X", "/HOLD", .console, &process) != r4os.abi.program_handle_ok) {
            _ = self.failBool("hold spawn");
            return null;
        }
        return process;
    }

    fn waitAndReapProgramHandle(self: *App, process: *r4os.abi.ProgramProcessHandle, max_ticks: u64) bool {
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (self.ctx.sys.programHandleWait(process, max_ticks, &completion) != r4os.abi.program_handle_ok)
            return false;
        if (self.ctx.sys.programHandleReap(process, &completion) != r4os.abi.program_handle_ok)
            return false;
        process.* = .{};
        return true;
    }

    fn cleanupProgramHandle(self: *App, process: *r4os.abi.ProgramProcessHandle, max_ticks: u64) void {
        if (process.instance_id == 0 or process.generation == 0 or process.reserved != 0) return;
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (self.ctx.sys.programHandleWait(process, 0, &completion) != r4os.abi.program_handle_ok) {
            _ = self.ctx.sys.programHandleKill(process);
            if (self.ctx.sys.programHandleWait(process, max_ticks, &completion) != r4os.abi.program_handle_ok)
                return;
        }
        if (self.ctx.sys.programHandleReap(process, &completion) == r4os.abi.program_handle_ok)
            process.* = .{};
    }

    fn waitOwnerResources(self: *App, id: u32, max_ticks: u32) bool {
        return self.waitOwnerCommitted(id, 2 * MB, max_ticks);
    }

    fn waitOwnerCommitted(self: *App, id: u32, min_committed: u64, max_ticks: u32) bool {
        var tick: u32 = 0;
        while (tick < max_ticks) : (tick += 1) {
            if (self.ownerResourceBlocks(id) >= 3 and self.ownerCommitted(id) >= min_committed) return true;
            self.ctx.sys.sleepTicks(1);
        }
        return self.ownerResourceBlocks(id) >= 3 and self.ownerCommitted(id) >= min_committed;
    }

    fn currentMemoryInfo(self: *App) ?r4os.abi.ProgramInstanceInfo {
        var attempt: u32 = 0;
        restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
            var cursor: r4os.abi.ProgramInventoryCursor = .{};
            var summary: r4os.abi.ProgramInventorySummary = .{};
            if (!self.beginProgramInventory(&cursor, &summary)) return null;
            while (true) {
                var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramInstanceSnapshot = undefined;
                var page: r4os.abi.ProgramInventoryPageInfo = .{};
                if (!self.readProgramInventoryPage(&cursor, entries[0..], &page)) return null;
                if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
                if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return null;
                for (entries[0..@intCast(page.returned)]) |entry| {
                    if (tagEquals(entry.info.memory_tag[0..], "memsuite")) return entry.info;
                }
                if (page.status == r4os.abi.program_inventory_status_complete) return null;
                if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return null;
            }
        }
        return null;
    }

    fn beginProgramInventory(
        self: *App,
        cursor: *r4os.abi.ProgramInventoryCursor,
        summary: *r4os.abi.ProgramInventorySummary,
    ) bool {
        var retry: u32 = 0;
        while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
            cursor.* = .{};
            summary.* = .{};
            const status = self.ctx.sys.programInventoryBegin(cursor, summary);
            if (status == r4os.abi.program_handle_ok) return true;
            if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
                return false;
            self.ctx.sys.sleepTicks(1);
        }
        return false;
    }

    fn readProgramInventoryPage(
        self: *App,
        cursor: *r4os.abi.ProgramInventoryCursor,
        entries: []r4os.abi.ProgramInstanceSnapshot,
        page: *r4os.abi.ProgramInventoryPageInfo,
    ) bool {
        var retry: u32 = 0;
        while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
            const cursor_before = cursor.*;
            page.* = .{};
            const status = self.ctx.sys.programInventoryPrograms(cursor, entries, page);
            if (status == r4os.abi.program_handle_ok) return true;
            cursor.* = cursor_before;
            page.* = .{};
            if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
                return false;
            self.ctx.sys.sleepTicks(1);
        }
        return false;
    }

    fn ownerResourceBlocks(self: *App, owner_id: u32) u64 {
        var count: u64 = 0;
        const block_count = self.ctx.dev.memoryBlockCount();
        var index: u32 = 0;
        while (index < block_count) : (index += 1) {
            const block = self.ctx.dev.memoryBlock(index) orelse continue;
            if (block.owner == tracked_owner_r4x and block.owner_id == owner_id and isTrackedKind(block.kind)) count += 1;
        }
        return count;
    }

    fn ownerCommitted(self: *App, owner_id: u32) u64 {
        var bytes: u64 = 0;
        const block_count = self.ctx.dev.memoryBlockCount();
        var index: u32 = 0;
        while (index < block_count) : (index += 1) {
            const block = self.ctx.dev.memoryBlock(index) orelse continue;
            if (block.owner == tracked_owner_r4x and block.owner_id == owner_id and isTrackedKind(block.kind)) bytes +%= block.committed_bytes;
        }
        return bytes;
    }

    fn resourceTotals(self: *App) ResourceTotals {
        var totals: ResourceTotals = .{};
        const block_count = self.ctx.dev.memoryBlockCount();
        var index: u32 = 0;
        while (index < block_count) : (index += 1) {
            const block = self.ctx.dev.memoryBlock(index) orelse continue;
            if (block.owner != tracked_owner_r4x or !isTrackedKind(block.kind)) continue;
            totals.blocks += 1;
            if (block.kind == tracked_kind_program_image) totals.program_images += 1;
            if (block.kind == tracked_kind_virtual_range) totals.vm_ranges += 1;
            if (block.kind == tracked_kind_app_stack) totals.app_stacks += 1;
            totals.reserved +%= block.reserved_bytes;
            totals.committed +%= block.committed_bytes;
            totals.physical +%= block.phys_len;
            totals.virtual +%= block.virt_len;
        }
        return totals;
    }

    fn resourceTotalsForOwner(self: *App, owner_id: u32) ResourceTotals {
        var totals: ResourceTotals = .{};
        const block_count = self.ctx.dev.memoryBlockCount();
        var index: u32 = 0;
        while (index < block_count) : (index += 1) {
            const block = self.ctx.dev.memoryBlock(index) orelse continue;
            if (block.owner != tracked_owner_r4x or block.owner_id != owner_id or !isTrackedKind(block.kind)) continue;
            totals.blocks += 1;
            if (block.kind == tracked_kind_program_image) totals.program_images += 1;
            if (block.kind == tracked_kind_virtual_range) totals.vm_ranges += 1;
            if (block.kind == tracked_kind_app_stack) totals.app_stacks += 1;
            totals.reserved +%= block.reserved_bytes;
            totals.committed +%= block.committed_bytes;
            totals.physical +%= block.phys_len;
            totals.virtual +%= block.virt_len;
        }
        return totals;
    }

    fn releaseIds(self: *App, ids: []u32) void {
        var i: usize = 0;
        while (i < ids.len) : (i += 1) {
            if (ids[i] != 0) {
                _ = self.ctx.sys.vmRelease(ids[i]);
                ids[i] = 0;
            }
        }
    }

    fn noteTableDuring(self: *App, stats: *VmStressStats) void {
        const current = self.resourceTotals().blocks;
        if (current > stats.table_during) stats.table_during = current;
    }

    fn printVmStressStats(self: *App, label: []const u8, stats: VmStressStats) void {
        self.ctx.sys.write("MEMSUITE ");
        self.ctx.sys.write(label);
        self.ctx.sys.write(": reservedMB=");
        self.ctx.sys.printU64(stats.reserved_bytes / MB);
        self.ctx.sys.write(" committedMB=");
        self.ctx.sys.printU64(stats.committed_bytes / MB);
        self.ctx.sys.write(" residentKB=");
        self.ctx.sys.printU64(stats.resident_bytes / KB);
        self.ctx.sys.write(" peakResidentKB=");
        self.ctx.sys.printU64(stats.peak_resident_bytes / KB);
        self.ctx.sys.write(" touchedPages=");
        self.ctx.sys.printU64(stats.touched_pages);
        self.ctx.sys.write(" pageFaults=");
        self.ctx.sys.printU64(stats.page_faults);
        self.ctx.sys.write(" failedFaults=");
        self.ctx.sys.printU64(stats.failed_faults);
        self.ctx.sys.write(" decommits=");
        self.ctx.sys.printU64(stats.decommits);
        self.ctx.sys.write(" limitErrors=");
        self.ctx.sys.printU64(stats.limit_errors);
        self.ctx.sys.write(" table=");
        self.ctx.sys.printU64(stats.table_before);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.table_during);
        self.ctx.sys.write("/");
        self.ctx.sys.printU64(stats.table_after);
        self.ctx.sys.write(" ownerCleanup=");
        self.ctx.sys.println(if (stats.cleanup_ok) "OK" else "FAILED");
    }

    fn printTotals(self: *App, label: []const u8, totals: ResourceTotals) void {
        self.ctx.sys.write("MEMSUITE ");
        self.ctx.sys.write(label);
        self.ctx.sys.write(": blocks=");
        self.ctx.sys.printU64(totals.blocks);
        self.ctx.sys.write(" images=");
        self.ctx.sys.printU64(totals.program_images);
        self.ctx.sys.write(" vm=");
        self.ctx.sys.printU64(totals.vm_ranges);
        self.ctx.sys.write(" stacks=");
        self.ctx.sys.printU64(totals.app_stacks);
        self.ctx.sys.write(" reserved=");
        self.ctx.sys.printU64(totals.reserved);
        self.ctx.sys.write(" committed=");
        self.ctx.sys.printU64(totals.committed);
        self.ctx.sys.println("");
    }

    fn printAllocatorStats(self: *App, label: []const u8, stats: r4os.vm_allocator.Stats) void {
        self.ctx.sys.write("MEMSUITE ");
        self.ctx.sys.write(label);
        self.ctx.sys.write(": active-bytes=");
        self.ctx.sys.printU64(stats.active_bytes);
        self.ctx.sys.write(" active=");
        self.ctx.sys.printU64(stats.active_allocations);
        self.ctx.sys.write(" committed=");
        self.ctx.sys.printU64(stats.committed_bytes);
        self.ctx.sys.println("");
    }

    fn failBool(self: *App, msg: []const u8) bool {
        self.ctx.sys.write("MEMSUITE FAILED: ");
        self.ctx.sys.println(msg);
        return false;
    }

    /// Zaehler, der ueber den Lauf null bleiben muss.
    fn checkZero(self: *App, name: []const u8, actual: u64) bool {
        if (actual == 0) return true;
        self.ctx.sys.write("MEMSUITE FAILED: pagerstress ");
        self.ctx.sys.write(name);
        self.ctx.sys.write(": actual=");
        self.ctx.sys.printU64(actual);
        self.ctx.sys.println(" expected=0");
        return false;
    }

    /// Wert, der eine Obergrenze nicht ueberschreiten darf.
    fn checkLimit(self: *App, name: []const u8, actual: u64, limit: u64) bool {
        if (actual <= limit) return true;
        self.ctx.sys.write("MEMSUITE FAILED: pagerstress ");
        self.ctx.sys.write(name);
        self.ctx.sys.write(": actual=");
        self.ctx.sys.printU64(actual);
        self.ctx.sys.write(" expected<=");
        self.ctx.sys.printU64(limit);
        self.ctx.sys.println("");
        return false;
    }

    /// Laufendes Maximum aus dem Kernel, das seit dem Boot waechst und nie
    /// zurueckgesetzt wird.
    ///
    /// Ein Delta ist hier BEDEUTUNGSLOS: max(nachher) minus max(vorher) sagt
    /// nichts, denn sind beide gleich, kann das Fenster einen gleich hohen
    /// Ausschlag gehabt haben oder gar keinen. Zurechenbar ist nur ein
    /// GEWACHSENES Maximum - dann wurde es in diesem Fenster gesetzt.
    ///
    /// Bewusste Restunschaerfe: Laege `before` bereits ueber `limit`, bliebe
    /// ein Ausschlag darunter unsichtbar. Deshalb gibt die Statistikzeile
    /// beide Werte aus - ein Wachsen von `before` waere damit sichtbar statt
    /// still.
    fn checkWindowMax(self: *App, name: []const u8, before: u64, after: u64, limit: u64) bool {
        if (after <= before) return true;
        if (after <= limit) return true;
        self.ctx.sys.write("MEMSUITE FAILED: pagerstress ");
        self.ctx.sys.write(name);
        self.ctx.sys.write(" max ticks newly set in window: before=");
        self.ctx.sys.printU64(before);
        self.ctx.sys.write(" after=");
        self.ctx.sys.printU64(after);
        self.ctx.sys.write(" expected<=");
        self.ctx.sys.printU64(limit);
        self.ctx.sys.println("");
        return false;
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var ctx = DiagApi.init(r4_app) orelse return r4os.abi.err_no_group;
    var app = App{ .ctx = &ctx };
    return app.run();
}

fn isTrackedKind(kind: u8) bool {
    return kind == tracked_kind_program_image or kind == tracked_kind_virtual_range or kind == tracked_kind_app_stack;
}

fn sameTotals(a: ResourceTotals, b: ResourceTotals) bool {
    return a.blocks == b.blocks and
        a.program_images == b.program_images and
        a.vm_ranges == b.vm_ranges and
        a.app_stacks == b.app_stacks and
        a.reserved == b.reserved and
        a.committed == b.committed and
        a.physical == b.physical and
        a.virtual == b.virtual;
}

fn pressureReclaimSourcesOk(
    pressure: r4os.abi.ProgramMemoryPressureSnapshot,
    performance: r4os.abi.ProgramPerformanceSummary,
) bool {
    // R4DEV deliberately reports every directly reclaimable PMM source:
    // clean FS-cache frames plus evictable VM pages.  The latter are not a
    // separate field in ProgramPerformanceSummary, so validate their
    // page-aligned remainder and matching capability flag instead of
    // comparing the combined value with
    // the FS-only counter.
    if (pressure.reclaimable_bytes == 0 or
        pressure.reclaimable_bytes < performance.fs_cache_pmm_reclaimable_bytes)
        return false;
    const vm_reclaimable = pressure.reclaimable_bytes - performance.fs_cache_pmm_reclaimable_bytes;
    if (vm_reclaimable % PAGE_SIZE != 0) return false;
    const vm_flag = (pressure.flags & r4os.abi.memory_pressure_flag_vm_page_reclaim) != 0;
    return (vm_reclaimable != 0) == vm_flag;
}

fn pressureDirtySourcesOk(
    pressure: r4os.abi.ProgramMemoryPressureSnapshot,
    performance: r4os.abi.ProgramPerformanceSummary,
) bool {
    if (pressure.dirty_bytes < performance.fs_cache_pmm_dirty_bytes or
        pressure.reclaimable_bytes < performance.fs_cache_pmm_reclaimable_bytes)
        return false;
    const vm_dirty = pressure.dirty_bytes - performance.fs_cache_pmm_dirty_bytes;
    const vm_reclaimable = pressure.reclaimable_bytes - performance.fs_cache_pmm_reclaimable_bytes;
    return vm_dirty <= vm_reclaimable and vm_dirty % PAGE_SIZE == 0;
}

fn deltaU64(after: u64, before: u64) u64 {
    if (after >= before) return after - before;
    return 0;
}

fn touch(mem: []u8, seed: u8) void {
    var offset: usize = 0;
    while (offset < mem.len) : (offset += 4096) {
        mem[offset] = seed +% @as(u8, @truncate(offset >> 12));
    }
    mem[mem.len - 1] = seed ^ 0x5A;
}

fn touchVmPages(mem: [*]u8, len: u64, seed: u8) u64 {
    var offset: u64 = 0;
    var pages: u64 = 0;
    var checksum: u8 = 0;
    while (offset < len) : (offset += PAGE_SIZE) {
        const index: usize = @intCast(offset);
        const value = seed +% @as(u8, @truncate(offset >> 12));
        mem[index] = value;
        checksum +%= mem[index];
        pages += 1;
    }
    touch_sink +%= checksum;
    return pages;
}

fn pagerStressPattern(cycle: u32, offset: usize) u8 {
    return @truncate((@as(usize, cycle) *% 29) +% (offset *% 7) +% 0x41);
}

fn argsContain(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (args[offset] != 0) {
        while (args[offset] == ' ' or args[offset] == '\t') : (offset += 1) {}
        if (args[offset] == 0) break;
        const start = offset;
        while (args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn tagEquals(tag: []const u8, expected: []const u8) bool {
    var len: usize = 0;
    while (len < tag.len and tag[len] != 0) : (len += 1) {}
    return equalsIgnoreCase(tag[0..len], expected);
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

fn asciiLower(ch: u8) u8 {
    if (ch >= 'A' and ch <= 'Z') return ch + 32;
    return ch;
}

fn pagefileBlockersOk(blockers: u32) bool {
    const required = r4os.abi.fs_cache_pagefile_blocker_no_pagefile |
        r4os.abi.fs_cache_pagefile_blocker_no_swap |
        r4os.abi.fs_cache_pagefile_blocker_no_pager;
    const forbidden = r4os.abi.fs_cache_pagefile_blocker_static_cache |
        r4os.abi.fs_cache_pagefile_blocker_no_global_reclaim;
    return (blockers & required) == required and (blockers & forbidden) == 0;
}

fn backingStoreReadyFlagsOk(flags: u32) bool {
    const required = r4os.abi.memory_backing_store_flag_file_backed |
        r4os.abi.memory_backing_store_flag_existing_file |
        r4os.abi.memory_backing_store_flag_fat32 |
        r4os.abi.memory_backing_store_flag_reserve_only |
        r4os.abi.memory_backing_store_flag_pager_disabled |
        r4os.abi.memory_backing_store_flag_uses_fs_api |
        r4os.abi.memory_backing_store_flag_no_second_io_path |
        r4os.abi.memory_backing_store_flag_page_aligned_request;
    return (flags & required) == required;
}

fn backingStoreSlotFlagsOk(flags: u32) bool {
    const required = r4os.abi.memory_backing_store_slot_flag_file_backed |
        r4os.abi.memory_backing_store_slot_flag_backing_ready |
        r4os.abi.memory_backing_store_slot_flag_metadata_only |
        r4os.abi.memory_backing_store_slot_flag_range_table |
        r4os.abi.memory_backing_store_slot_flag_page_sized_slots |
        r4os.abi.memory_backing_store_slot_flag_pager_disabled |
        r4os.abi.memory_backing_store_slot_flag_recovery_available;
    const forbidden = r4os.abi.memory_backing_store_slot_flag_eviction_disabled |
        r4os.abi.memory_backing_store_slot_flag_no_page_io;
    return (flags & required) == required and (flags & forbidden) == 0;
}

fn pagerGateFlagsOk(flags: u32) bool {
    const required = r4os.abi.memory_pager_gate_flag_file_backed |
        r4os.abi.memory_pager_gate_flag_backing_ready |
        r4os.abi.memory_pager_gate_flag_metadata_only |
        r4os.abi.memory_pager_gate_flag_vm_region_attached |
        r4os.abi.memory_pager_gate_flag_commit_gate |
        r4os.abi.memory_pager_gate_flag_fault_gate |
        r4os.abi.memory_pager_gate_flag_slot_reservation_tested |
        r4os.abi.memory_pager_gate_flag_rollback_complete |
        r4os.abi.memory_pager_gate_flag_pager_disabled |
        r4os.abi.memory_pager_gate_flag_no_page_io |
        r4os.abi.memory_pager_gate_flag_no_swap |
        r4os.abi.memory_pager_gate_flag_no_second_io_path |
        r4os.abi.memory_pager_gate_flag_page_sized_slots;
    return (flags & required) == required;
}

fn pageIoFlagsOk(flags: u32, operation: u32) bool {
    const required = r4os.abi.memory_page_io_flag_file_backed |
        r4os.abi.memory_page_io_flag_backing_ready |
        r4os.abi.memory_page_io_flag_vm_region_attached |
        r4os.abi.memory_page_io_flag_slot_reserved |
        r4os.abi.memory_page_io_flag_slot_valid |
        r4os.abi.memory_page_io_flag_slot_clean |
        r4os.abi.memory_page_io_flag_explicit_request |
        r4os.abi.memory_page_io_flag_uses_fs_api |
        r4os.abi.memory_page_io_flag_no_second_io_path |
        r4os.abi.memory_page_io_flag_pager_disabled |
        r4os.abi.memory_page_io_flag_no_swap |
        r4os.abi.memory_page_io_flag_page_sized_slots |
        r4os.abi.memory_page_io_flag_owner_matched |
        r4os.abi.memory_page_io_flag_generation_checked |
        r4os.abi.memory_page_io_flag_multi_page;
    const op_flag = if (operation == r4os.abi.memory_page_io_operation_page_in)
        r4os.abi.memory_page_io_flag_page_in
    else
        r4os.abi.memory_page_io_flag_page_out;
    return (flags & (required | op_flag)) == (required | op_flag);
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}
