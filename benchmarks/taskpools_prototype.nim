## Prototype of Mummy with taskpools integration
## This demonstrates how taskpools could replace the current threading system

import ../src/mummy, ../src/mummy/routers
import std/[times, strutils, httpclient, asyncdispatch, random, sequtils, locks, os]
import taskpools

var requestCount = 0
var requestLock: Lock
initLock(requestLock)

# Global taskpool for request handling
var globalTaskPool: TaskPool

proc handleSimpleRequest(request: Request) {.gcsafe.} =
  # This proc will be spawned on the taskpool
  withLock requestLock:
    inc requestCount
  
  # Simulate some work
  let work = rand(1..10) # Random work 1-10ms
  sleep(work)
  
  request.respond(200, @[("Content-Type", "text/plain")], "Request #" & $requestCount)

proc handleJSONRequest(request: Request) {.gcsafe.} =
  # This proc will be spawned on the taskpool
  withLock requestLock:
    inc requestCount
  
  # Simulate JSON processing work
  let jsonData = """{"message": "Hello", "count": """ & $requestCount & """, "timestamp": """ & $now().toTime().toUnix() & """}"""
  
  # Some CPU work
  for i in 1..1000:
    discard jsonData.len * i
  
  request.respond(200, @[("Content-Type", "application/json")], jsonData)

# Wrapper to demonstrate taskpool request handling
proc taskpoolRequestHandler(request: Request) {.gcsafe.} =
  # In a real implementation, this would be integrated into Mummy's core
  # For now, we simulate by spawning the work
  if request.path == "/simple":
    spawn globalTaskPool, handleSimpleRequest(request)
  elif request.path == "/json":
    spawn globalTaskPool, handleJSONRequest(request)
  else:
    request.respond(404, @[("Content-Type", "text/plain")], "Not Found")

proc runTaskpoolBenchmark(numRequests: int, concurrency: int): float =
  echo "Starting taskpool benchmark: ", numRequests, " requests with concurrency ", concurrency
  
  # Initialize taskpool with dynamic sizing
  globalTaskPool = Taskpool.new()
  
  var router = Router()
  router.get("/simple", taskpoolRequestHandler)
  router.get("/json", taskpoolRequestHandler)
  
  # Use fewer fixed threads since taskpool handles the work
  let server = newServer(router, workerThreads = 2) 
  
  var serverThread: Thread[void]
  createThread(serverThread, proc() =
    server.serve(Port(9998))
  )
  
  sleep(100) # Give server time to start
  
  let startTime = cpuTime()
  
  proc makeRequests() {.async.} =
    var clients: seq[AsyncHttpClient] = @[]
    var futures: seq[Future[void]] = @[]
    
    for i in 0 ..< concurrency:
      clients.add(newAsyncHttpClient())
    
    for reqNum in 0 ..< numRequests:
      let clientIdx = reqNum mod concurrency
      let endpoint = if reqNum mod 2 == 0: "/simple" else: "/json"
      
      futures.add(clients[clientIdx].get("http://localhost:9998" & endpoint).then(
        proc(resp: Response): Future[void] {.async.} =
          discard await resp.body
      ))
    
    await all(futures)
    
    for client in clients:
      client.close()
  
  waitFor makeRequests()
  
  let endTime = cpuTime()
  let totalTime = endTime - startTime
  
  echo "Completed ", numRequests, " requests in ", totalTime, " seconds"
  echo "Requests per second: ", numRequests.float / totalTime
  echo "Average latency: ", (totalTime / numRequests.float) * 1000, " ms"
  
  server.close()
  joinThread(serverThread)
  globalTaskPool.close()
  
  return numRequests.float / totalTime

proc main() =
  echo "=== Mummy Taskpools Prototype Benchmark ==="
  
  let scenarios = [
    (100, 10),   # 100 requests, 10 concurrent
    (500, 20),   # 500 requests, 20 concurrent  
    (1000, 50),  # 1000 requests, 50 concurrent
  ]
  
  for (requests, concurrency) in scenarios:
    let rps = runTaskpoolBenchmark(requests, concurrency)
    echo "Result: ", rps, " RPS"
    echo "---"
    sleep(1000) # Cool down between tests

when isMainModule:
  randomize()
  main()