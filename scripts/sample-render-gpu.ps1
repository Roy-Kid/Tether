# Evaluation sidecar: process-specific Windows GPU engine counters, not a
# global nvidia-smi percentage contaminated by unrelated applications.
param([int]$ProcessId, [string]$Output, [int]$MaxSeconds = 120)
$ErrorActionPreference = 'Stop'
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($MaxSeconds)
    while ([DateTime]::UtcNow -lt $deadline -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
        # Engines can disappear during collection when any desktop process
        # exits. Preserve valid target samples instead of failing the whole
        # capture because an unrelated process's counter became invalid.
        $sample = Get-Counter '\GPU Engine(*)\Utilization Percentage','\GPU Process Memory(*)\Dedicated Usage','\GPU Process Memory(*)\Shared Usage' -MaxSamples 1 -ErrorAction SilentlyContinue
        if (-not $sample) { throw 'GPU engine counters unavailable' }
        $targetSamples = @($sample.CounterSamples | Where-Object { $_.Path -match "pid_${ProcessId}_" })
        $engines = @($targetSamples | Where-Object { $_.Status -eq 0 -and $_.Path -match 'gpu engine' } |
            ForEach-Object { @{ path = $_.Path; percent = $_.CookedValue } })
        $memory = @($targetSamples | Where-Object { $_.Status -eq 0 -and $_.Path -match 'gpu process memory' } |
            ForEach-Object { @{ path = $_.Path; bytes = [long]$_.CookedValue } })
        @{ utc = $sample.Timestamp.ToUniversalTime().ToString('o'); qpc = [Diagnostics.Stopwatch]::GetTimestamp(); engines = $engines; gpu_memory = $memory; invalid_samples = @($targetSamples | Where-Object { $_.Status -ne 0 }).Count } |
            ConvertTo-Json -Depth 4 -Compress | Add-Content -LiteralPath $Output -Encoding utf8
    }
} catch {
    @{ status = 'unverified'; error = $_.Exception.Message } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $Output -Encoding utf8
    exit 1
}
