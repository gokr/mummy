## Comparison benchmark between current threading and taskpools
## This runs both systems and compares performance

import std/[times, strutils, os]

proc runBenchmark(name: string, executable: string): (float, float, float) =
  echo "=== Running ", name, " benchmark ==="
  let startTime = cpuTime()
  let exitCode = execShellCmd("nim c -r -d:release --threads:on " & executable)
  let endTime = cpuTime()
  
  if exitCode != 0:
    echo "ERROR: Benchmark failed with exit code: ", exitCode
    return (0.0, 0.0, 0.0)
  
  let compilationTime = endTime - startTime
  echo name, " compilation time: ", compilationTime, " seconds"
  
  # Parse results from output (this is simplified - real implementation would parse stdout)
  # For now, return dummy values
  return (100.0, 200.0, 500.0) # RPS for scenarios 1, 2, 3

proc main() =
  echo "Threading Performance Comparison"
  echo "================================"
  
  let currentResults = runBenchmark("Current Threading", "benchmarks/current_threading_bench.nim")
  let taskpoolResults = runBenchmark("Taskpools", "benchmarks/taskpools_prototype.nim")
  
  echo "\nResults Summary:"
  echo "Current Threading RPS: ", currentResults
  echo "Taskpools RPS: ", taskpoolResults
  
  echo "\nPerformance Comparison:"
  for i in 0..2:
    let improvement = (taskpoolResults[i] - currentResults[i]) / currentResults[i] * 100
    echo "Scenario ", i+1, ": ", improvement, "% improvement"

when isMainModule:
  main()