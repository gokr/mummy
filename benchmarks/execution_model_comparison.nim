## Performance comparison between ThreadPool and TaskPools execution models
## This benchmark tests the actual implemented taskpools vs threadpool execution

import ../src/mummy, ../src/mummy/routers
import std/[times, strutils, httpclient, random, os, cpuinfo, math, locks]

type
  BenchmarkResult = object
    executionModel: string
    requests: int
    concurrency: int
    totalTime: float
    requestsPerSecond: float
    successfulRequests: int

var
  requestCount = 0
  requestLock: Lock

initLock(requestLock)

proc resetCounters() =
  withLock requestLock:
    requestCount = 0

proc handleBenchmarkRequest(request: Request) {.gcsafe.} =
  withLock requestLock:
    inc requestCount
  
  # Simulate different types of work based on path
  case request.path:
  of "/light":
    # Light CPU work
    for i in 1..100:
      discard i * i
    request.respond(200, @[("Content-Type", "text/plain")], "Light work completed #" & $requestCount)
  
  of "/medium":
    # Medium CPU + I/O simulation
    for i in 1..1000:
      discard i * i * i
    sleep(1) # Simulate 1ms I/O
    let jsonData = """{"message": "Medium work", "count": """ & $requestCount & """, "timestamp": """ & $now().toTime().toUnix() & """}"""
    request.respond(200, @[("Content-Type", "application/json")], jsonData)
  
  of "/heavy":
    # Heavy CPU work
    for i in 1..5000:
      discard i * i * i * i
    sleep(2) # Simulate 2ms I/O
    request.respond(200, @[("Content-Type", "text/plain")], "Heavy work completed #" & $requestCount)
  
  else:
    request.respond(404, @[("Content-Type", "text/plain")], "Not Found")

proc makeHttpRequests(port: int, numRequests: int, concurrency: int): int =
  var successCount = 0
  var clients: seq[HttpClient] = @[]
  
  # Create HTTP clients
  for i in 0 ..< concurrency:
    clients.add(newHttpClient(timeout = 10000)) # 10 second timeout
  
  # Distribute requests across different endpoints
  for reqNum in 0 ..< numRequests:
    let clientIdx = reqNum mod concurrency
    let endpoint = case reqNum mod 3:
      of 0: "/light"
      of 1: "/medium"
      else: "/heavy"
    
    try:
      let response = clients[clientIdx].get("http://localhost:" & $port & endpoint)
      if response.code == Http200:
        inc successCount
      else:
        echo "Error response: ", response.code
    except:
      echo "Request failed: ", getCurrentExceptionMsg()
  
  for client in clients:
    client.close()
  
  return successCount

proc runBenchmark(executionModel: ExecutionModel, numRequests: int, concurrency: int, port: int): BenchmarkResult =
  echo "=== Benchmarking ", $executionModel, " ==="
  echo "Requests: ", numRequests, ", Concurrency: ", concurrency, ", Port: ", port
  
  resetCounters()
  
  var router = Router()
  router.get("/light", handleBenchmarkRequest)
  router.get("/medium", handleBenchmarkRequest)
  router.get("/heavy", handleBenchmarkRequest)
  
  # Configure server based on execution model
  let workerThreads = if executionModel == TaskPools: max(2, countProcessors() div 2) else: countProcessors() * 2
  let server = newServer(
    handler = router,
    workerThreads = workerThreads,
    executionModel = executionModel
  )
  
  echo "Starting server with ", workerThreads, " worker threads"
  
  var serverThread: Thread[void]
  proc serverProc() {.thread.} =
    server.serve(Port(port))
  
  createThread(serverThread, serverProc)
  
  sleep(1000) # Give server time to start
  
  let startTime = cpuTime()
  
  let successfulRequests = makeHttpRequests(port, numRequests, concurrency)
  
  let endTime = cpuTime()
  let totalTime = endTime - startTime
  
  # Calculate statistics
  let rps = successfulRequests.float / totalTime
  
  echo "Completed ", successfulRequests, "/", numRequests, " requests in ", totalTime.formatFloat(ffDecimal, 3), " seconds"
  echo "Requests per second: ", rps.formatFloat(ffDecimal, 2)
  echo "Success rate: ", (successfulRequests.float / numRequests.float * 100).formatFloat(ffDecimal, 1), "%"
  echo ""
  
  server.close()
  joinThread(serverThread)
  
  sleep(1000) # Cool down between tests
  
  return BenchmarkResult(
    executionModel: $executionModel,
    requests: numRequests,
    concurrency: concurrency,
    totalTime: totalTime,
    requestsPerSecond: rps,
    successfulRequests: successfulRequests
  )

proc printComparison(threadPoolResult, taskPoolsResult: BenchmarkResult) =
  echo "=== PERFORMANCE COMPARISON ==="
  echo "Scenario: ", threadPoolResult.requests, " requests, ", threadPoolResult.concurrency, " concurrency"
  echo ""
  
  echo "ThreadPool Results:"
  echo "  RPS: ", threadPoolResult.requestsPerSecond.formatFloat(ffDecimal, 2)
  echo "  Success Rate: ", (threadPoolResult.successfulRequests.float / threadPoolResult.requests.float * 100).formatFloat(ffDecimal, 1), "%"
  echo "  Total Time: ", threadPoolResult.totalTime.formatFloat(ffDecimal, 3), " seconds"
  echo ""
  
  echo "TaskPools Results:"
  echo "  RPS: ", taskPoolsResult.requestsPerSecond.formatFloat(ffDecimal, 2)
  echo "  Success Rate: ", (taskPoolsResult.successfulRequests.float / taskPoolsResult.requests.float * 100).formatFloat(ffDecimal, 1), "%"
  echo "  Total Time: ", taskPoolsResult.totalTime.formatFloat(ffDecimal, 3), " seconds"
  echo ""
  
  # Calculate improvements
  if threadPoolResult.requestsPerSecond > 0:
    let rpsImprovement = ((taskPoolsResult.requestsPerSecond - threadPoolResult.requestsPerSecond) / threadPoolResult.requestsPerSecond) * 100
    let timeImprovement = ((threadPoolResult.totalTime - taskPoolsResult.totalTime) / threadPoolResult.totalTime) * 100
    
    echo "Performance Difference:"
    if rpsImprovement > 0:
      echo "  TaskPools is ", rpsImprovement.formatFloat(ffDecimal, 1), "% FASTER in RPS"
    else:
      echo "  ThreadPool is ", (-rpsImprovement).formatFloat(ffDecimal, 1), "% FASTER in RPS"
    
    if timeImprovement > 0:
      echo "  TaskPools completed ", timeImprovement.formatFloat(ffDecimal, 1), "% FASTER"
    else:
      echo "  ThreadPool completed ", (-timeImprovement).formatFloat(ffDecimal, 1), "% FASTER"
  
  echo "=" .repeat(50)
  echo ""

proc main() =
  echo "=== MUMMY EXECUTION MODEL PERFORMANCE COMPARISON ==="
  echo "System Info: ", countProcessors(), " CPU cores"
  echo ""
  
  let scenarios = [
    (50, 5),     # Light load
    (200, 10),   # Medium load  
    (500, 20),   # Heavy load
  ]
  
  for (requests, concurrency) in scenarios:
    echo "SCENARIO: ", requests, " requests with ", concurrency, " concurrent connections"
    echo ""
    
    # Test ThreadPool first
    let threadPoolResult = runBenchmark(ThreadPool, requests, concurrency, 8080)
    
    # Test TaskPools second  
    let taskPoolsResult = runBenchmark(TaskPools, requests, concurrency, 8081)
    
    # Print comparison
    printComparison(threadPoolResult, taskPoolsResult)

when isMainModule:
  randomize()
  main()