## Example demonstrating Mummy's ExecutionModel options
## 
## This example shows how to configure different execution models:
## - ThreadPool: Traditional fixed thread pool (default)
## - TaskPools: Future taskpools-based dynamic execution (placeholder for now)

import ../src/mummy, ../src/mummy/routers
import std/[times, strutils, os]

proc handleRequest(request: Request) {.gcsafe.} =
  let path = request.path
  case path:
  of "/threadpool":
    request.respond(200, @[("Content-Type", "text/plain")], 
      "Handled by ThreadPool execution model at " & $now())
  of "/taskpools":
    request.respond(200, @[("Content-Type", "text/plain")], 
      "Handled by TaskPools execution model at " & $now())
  of "/info":
    request.respond(200, @[("Content-Type", "text/plain")], 
      "Server info: Request processed successfully")
  else:
    request.respond(404, @[("Content-Type", "text/plain")], 
      "Path not found: " & path)

proc demonstrateThreadPool() =
  echo "=== ThreadPool Execution Model Demo ==="
  
  var router = Router()
  router.get("/*", handleRequest)
  
  # Create server with traditional thread pool execution
  let server = newServer(
    handler = router,  # Router automatically converted to RequestHandler
    workerThreads = 4,
    executionModel = ThreadPool  # Explicit ThreadPool mode
  )
  
  echo "Server running on http://localhost:8080 with ThreadPool execution"
  echo "Try: curl http://localhost:8080/threadpool"
  echo "Try: curl http://localhost:8080/info"
  echo "Press Ctrl+C to stop"
  
  server.serve(Port(8080))

proc demonstrateTaskPools() =
  echo "=== TaskPools Execution Model Demo ==="
  
  var router = Router()
  router.get("/*", handleRequest)
  
  # Create server with taskpools execution (currently uses ThreadPool internally)
  let server = newServer(
    handler = router,  # Router automatically converted to RequestHandler
    workerThreads = 4,
    executionModel = TaskPools  # Future TaskPools mode
  )
  
  echo "Server running on http://localhost:8081 with TaskPools execution"
  echo "Note: TaskPools currently uses ThreadPool internally - full implementation coming soon"
  echo "Try: curl http://localhost:8081/taskpools"
  echo "Try: curl http://localhost:8081/info"
  echo "Press Ctrl+C to stop"
  
  server.serve(Port(8081))

proc main() =
  let args = commandLineParams()
  
  if args.len == 0:
    echo "Usage: execution_models [threadpool|taskpools]"
    echo ""
    echo "Examples:"
    echo "  execution_models threadpool  # Demonstrate ThreadPool execution"
    echo "  execution_models taskpools   # Demonstrate TaskPools execution"
    return
  
  case args[0]:
  of "threadpool":
    demonstrateThreadPool()
  of "taskpools":
    demonstrateTaskPools()
  else:
    echo "Unknown execution model: ", args[0]
    echo "Available options: threadpool, taskpools"

when isMainModule:
  main()