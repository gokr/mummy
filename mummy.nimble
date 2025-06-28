version     = "0.4.6"
author      = "Ryan Oldenburg"
description = "Multithreaded HTTP + WebSocket server"
license     = "MIT"

srcDir = "src"

requires "nim >= 1.6.8"
requires "zippy >= 0.10.9"
requires "webby >= 0.2.1"
requires "crunchy >= 0.1.11"
requires "taskpools >= 0.0.3"

# Test task that will install test dependencies and run tests
task test, "Run tests":
  requires "jsony >= 1.1.5"
  requires "whisky >= 0.1.3"
  
  exec "nim c -r tests/test.nim"
  exec "nim c -r tests/test_http.nim"
  exec "nim c -r tests/test_http2.nim"
  exec "nim c -r tests/test_websockets.nim"
  exec "nim c -r tests/test_multipart.nim"
  exec "nim c -r tests/test_routers.nim"
  exec "nim c -r tests/test_sse.nim"
  exec "nim c -r tests/test_sse_simple.nim"
  exec "nim c -r tests/test_sse_final.nim"
