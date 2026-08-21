[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Init', 'Get', 'Validate')]
    [string]$Mode,
    [ValidateSet('goal_run', 'interactive')]
    [string]$WorkflowMode = 'goal_run',
    [ValidateSet('final_only', 'per_unit')]
    [string]$ReportPolicy = 'final_only',
    [ValidateSet('safe_pipeline', 'adaptive', 'serial')]
    [string]$ParallelMode = 'safe_pipeline',
    [ValidateSet('auto', 'classic', 'long_run_batch')]
    [string]$ExecutionProfile = 'auto',
    [ValidateRange(1, 4)]
    [int]$MaxWorkers = 4,
    [ValidateSet('preserve_source_strip_export', 'preserve_everywhere')]
    [string]$LegacyPreviewPolicy = 'preserve_source_strip_export',
    [int]$PreviewDisabledFromEpisode = 0,
    [ValidateRange(1, 9)]
    [int]$PrefetchWindow = 3,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ComicAdapt.Common.psm1') -Force
$root = (Resolve-Path -LiteralPath $ProjectRoot).Path
$policyPath = Join-Path $root '.comic-adapt\policy.json'

function Read-Policy {
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) { return $null }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $policyPath | ConvertFrom-Json
}

function Test-Policy([object]$Policy) {
    $errors = New-Object Collections.Generic.List[string]
    if (-not $Policy) { $errors.Add('policy is missing'); return $errors.ToArray() }
    if ([string]$Policy.schema_version -ne 'comic-adapt-policy/1.0') { $errors.Add('unsupported schema_version') }
    if ([string]$Policy.workflow_mode -notin @('goal_run', 'interactive')) { $errors.Add('invalid workflow_mode') }
    if ([string]$Policy.report_policy -notin @('final_only', 'per_unit')) { $errors.Add('invalid report_policy') }
    if ([bool]$Policy.preview_enabled) { $errors.Add('V6 requires preview_enabled=false') }
    if ([int]$Policy.preview_disabled_from_episode -lt 1) { $errors.Add('preview_disabled_from_episode must be positive') }
    if ([string]$Policy.parallel_mode -notin @('safe_pipeline', 'adaptive', 'serial')) { $errors.Add('invalid parallel_mode') }
    if ($Policy.PSObject.Properties['execution_profile'] -and [string]$Policy.execution_profile -notin @('auto', 'classic', 'long_run_batch')) { $errors.Add('invalid execution_profile') }
    if ([int]$Policy.max_workers -lt 1 -or [int]$Policy.max_workers -gt 4) { $errors.Add('max_workers must be 1..4') }
    if ([string]$Policy.time_model -ne 'source_relative') { $errors.Add('V6 requires time_model=source_relative') }
    if ([int]$Policy.source_time_from_episode -lt 1) { $errors.Add('source_time_from_episode must be positive') }
    if ($Policy.PSObject.Properties['prefetch_window'] -and ([int]$Policy.prefetch_window -lt 1 -or [int]$Policy.prefetch_window -gt 9)) { $errors.Add('prefetch_window must be 1..9') }
    if ($Policy.PSObject.Properties['batch_sizes'] -and (@($Policy.batch_sizes) -join ',') -ne '3,6,9') { $errors.Add('batch_sizes must be 3,6,9') }
    if ($Policy.PSObject.Properties['batch_checker_max'] -and ([int]$Policy.batch_checker_max -lt 1 -or [int]$Policy.batch_checker_max -gt 10)) { $errors.Add('batch_checker_max must be 1..10') }
    if ($Policy.PSObject.Properties['draft_workers'] -and ([int]$Policy.draft_workers -lt 1 -or [int]$Policy.draft_workers -gt 3)) { $errors.Add('draft_workers must be 1..3') }
    if ($Policy.PSObject.Properties['writer_brief_token_limit'] -and [int]$Policy.writer_brief_token_limit -lt 1000) { $errors.Add('writer_brief_token_limit must be >=1000') }
    if ($Policy.PSObject.Properties['write_packet_token_limit'] -and [int]$Policy.write_packet_token_limit -lt [int]$Policy.writer_brief_token_limit) { $errors.Add('write_packet_token_limit must be >= writer_brief_token_limit') }
    if ($Policy.PSObject.Properties['visual_history_inheritance'] -and [string]$Policy.visual_history_inheritance -ne 'nearest_ready_per_entity') { $errors.Add('invalid visual_history_inheritance') }
    if (-not [bool]$Policy.single_commit_writer) { $errors.Add('single_commit_writer must be true') }
    return $errors.ToArray()
}

if ($Mode -eq 'Init') {
    if ((Test-Path -LiteralPath $policyPath -PathType Leaf) -and -not $Force) {
        $existingPolicy = Read-Policy
        $changed = $false
        $scriptDirForUpgrade = Join-Path $root 'scripts'
        $existingEpisodeNumbers = if (Test-Path -LiteralPath $scriptDirForUpgrade -PathType Container) {
            @(Get-ChildItem -LiteralPath $scriptDirForUpgrade -File -Filter 'EP-*.md' | ForEach-Object { if ($_.Name -match '^EP-0*(\d+)\.md$') { [int]$Matches[1] } })
        } else { @() }
        $sourceTimeFrom = if ($existingEpisodeNumbers.Count -gt 0) { [int](($existingEpisodeNumbers | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
        $defaults = [ordered]@{
            prefetch_window = 3
            execution_profile = 'auto'
            long_run_min_episodes = 6
            batch_sizes = @(3, 6, 9)
            batch_checker_max = 10
            draft_workers = 3
            max_batch_lead = 1
            batch_failure_isolation = 'failed_and_adjacent'
            candidate_manifest_required = $true
            batch_visual_finalize = $true
            double_hash = $true
            compact_context = $true
            index_validation = 'goal_full_target_fast'
            pre_review_scheduler = 'adaptive'
            commit_journal = $true
            time_model = 'source_relative'
            source_time_from_episode = $sourceTimeFrom
            mutable_contract_refresh = $true
            require_closed_scopes_before_finish = $true
            draft_gate_before_parallel = $true
            commit_machine_closure = $true
            writer_brief_token_limit = 2200
            write_packet_token_limit = 5000
            visual_history_inheritance = 'nearest_ready_per_entity'
            continue_on_unresolved = $true
            single_commit_writer = $true
        }
        foreach ($entry in $defaults.GetEnumerator()) {
            if (-not $existingPolicy.PSObject.Properties[$entry.Key]) {
                $existingPolicy | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value
                $changed = $true
            }
        }
        foreach ($obsolete in @('legacy_calendar_policy', 'compatibility_mode', 'legacy_preview_scope', 'legacy_calendar_scope')) {
            if ($existingPolicy.PSObject.Properties[$obsolete]) {
                $existingPolicy.PSObject.Properties.Remove($obsolete)
                $changed = $true
            }
        }
        if ([int]$existingPolicy.writer_brief_token_limit -eq 3500) { $existingPolicy.writer_brief_token_limit = 2200; $changed = $true }
        if ([int]$existingPolicy.write_packet_token_limit -eq 10000) { $existingPolicy.write_packet_token_limit = 5000; $changed = $true }
        if ($changed) {
            Write-JsonAtomic $policyPath $existingPolicy
            Write-Output "WORKFLOW-POLICY-UPGRADE: $policyPath"
        } else {
            Write-Output "WORKFLOW-POLICY-SKIP: $policyPath"
        }
        exit 0
    }
    if ($PreviewDisabledFromEpisode -le 0) {
        $scriptDir = Join-Path $root 'scripts'
        $existing = if (Test-Path -LiteralPath $scriptDir -PathType Container) {
            @(Get-ChildItem -LiteralPath $scriptDir -File -Filter 'EP-*.md' | ForEach-Object {
                if ($_.Name -match '^EP-0*(\d+)\.md$') { [int]$Matches[1] }
            } | Where-Object { $_ -gt 0 })
        } else { @() }
        $PreviewDisabledFromEpisode = if ($existing.Count -gt 0) { [int](($existing | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
    }
    $policy = [ordered]@{
        schema_version = 'comic-adapt-policy/1.0'
        workflow_mode = $WorkflowMode
        report_policy = $ReportPolicy
        preview_enabled = $false
        preview_disabled_from_episode = $PreviewDisabledFromEpisode
        parallel_mode = $ParallelMode
        execution_profile = $ExecutionProfile
        max_workers = $MaxWorkers
        prefetch_window = $PrefetchWindow
        long_run_min_episodes = 6
        batch_sizes = @(3, 6, 9)
        batch_checker_max = 10
        draft_workers = [Math]::Min(3, [Math]::Max(1, $MaxWorkers - 1))
        max_batch_lead = 1
        batch_failure_isolation = 'failed_and_adjacent'
        candidate_manifest_required = $true
        batch_visual_finalize = $true
        double_hash = $true
        compact_context = $true
        index_validation = 'goal_full_target_fast'
        pre_review_scheduler = 'adaptive'
        commit_journal = $true
        time_model = 'source_relative'
        source_time_from_episode = $PreviewDisabledFromEpisode
        mutable_contract_refresh = $true
        require_closed_scopes_before_finish = $true
        draft_gate_before_parallel = $true
        commit_machine_closure = $true
        writer_brief_token_limit = 2200
        write_packet_token_limit = 5000
        visual_history_inheritance = 'nearest_ready_per_entity'
        continue_on_unresolved = $true
        single_commit_writer = $true
        legacy_preview_policy = $LegacyPreviewPolicy
        created_at = (Get-Date).ToString('o')
    }
    Write-JsonAtomic $policyPath $policy
    Write-Output ("WORKFLOW-POLICY-INIT: mode={0}; profile={1}; report={2}; preview=false-from-EP-{3}; parallel={4}; workers={5}; path={6}" -f $WorkflowMode, $ExecutionProfile, $ReportPolicy, $PreviewDisabledFromEpisode.ToString('D2'), $ParallelMode, $MaxWorkers, $policyPath)
    exit 0
}

$policy = Read-Policy
if (-not $policy) { Write-Output "WORKFLOW-POLICY-MISSING: $policyPath"; exit 2 }
$errors = @(Test-Policy $policy)
if ($errors.Count -gt 0) {
    foreach ($issue in $errors) { Write-Output "WORKFLOW-POLICY-FAIL: $issue" }
    exit 1
}
if ($Mode -eq 'Get') { $policy | ConvertTo-Json -Depth 12; exit 0 }
Write-Output ("WORKFLOW-POLICY-PASS: mode={0}; profile={1}; report={2}; preview={3}; preview-from=EP-{4}; parallel={5}; workers={6}" -f $policy.workflow_mode, $policy.execution_profile, $policy.report_policy, $policy.preview_enabled, ([int]$policy.preview_disabled_from_episode).ToString('D2'), $policy.parallel_mode, $policy.max_workers)
exit 0
