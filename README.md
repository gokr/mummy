# MummyX
Welcome to MummyX! This is [Mummy](https://github.com/guzba/mummy) + eXtra features. I try to track Mummy upstream but several of the extra features added in MummyX will never be merged upstream. This is actually **quite fine**, Mummy has been rock stable for years and I have no interest in breaking that.

But if you need **SSE**, **industry standard large file uploads** or is interested in **taskpool concurrency** instead of threadpool - then MummyX might be for you.

## Background
I got tired of async/await and wanted to go with threads instead so that I can use blocking libraries in handlers etc. I found Mummy by guzba and it looked very solidly built. I am using Mummy as a core part of a Nim backend I am building for [Tankfeud](https://tankfeud.com) using the excellent Websocket support in Mummy.

But lately I started playing with MCP and created [NimCP](https://github.com/gokr/nimcp) using Mummy as the HTTP server. MCP needs SSE (and Websockets) but Mummy was lacking SSE support. So... I felt, ok, with the power of Claude, I can add SSE to Mummy! So I did, and then I added large file upload support because someone said Mummy was lacking it (Claude Code is amazing). And then I added taskpool support (because threadpool is actually being deprecated).

And yeah, after conferring with guzba I decided to rename this repository to **MummyX**. But for now package name will stay `mummy` for compatibility.

## Installation

`nimble install mummyx`


## Example HTTP server

```nim
import mummy, mummy/routers

proc indexHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain"
  request.respond(200, headers, "Hello, World!")

var router: Router
router.get("/", indexHandler)

let server = newServer(router)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
```

`nim c --threads:on --mm:orc -r examples/basic_router.nim`

## Example WebSocket server

```nim
import mummy, mummy/routers

proc indexHandler(request: Request) =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  request.respond(200, headers, """
  <script>
    var ws = new WebSocket("ws://localhost:8080/ws");
    ws.onmessage = function (event) {
      document.body.innerHTML = event.data;
    };
  </script>
  """)

proc upgradeHandler(request: Request) =
  let websocket = request.upgradeToWebSocket()
  websocket.send("Hello world from WebSocket!")

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) =
  case event:
  of OpenEvent:
    discard
  of MessageEvent:
    echo message.kind, ": ", message.data
  of ErrorEvent:
    discard
  of CloseEvent:
    discard

var router: Router
router.get("/", indexHandler)
router.get("/ws", upgradeHandler)

let server = newServer(router, websocketHandler)
echo "Serving on http://localhost:8080"
server.serve(Port(8080))
```

See the examples/ folder for more sample code, including an example WebSocket chat server.

`nim c --threads:on --mm:orc -r examples/basic_websockets.nim`

## Benchmarking

The tests/wrk_ servers can be used for benchmarking and attempt to simulate requests that take ~10ms to complete.

Test for example with:

`wrk -t10 -c100 -d10s http://localhost:8080`

## Testing

A fuzzer has been run against Mummy's socket reading and parsing code to ensure Mummy does not crash or otherwise misbehave on bad data from sockets. You can run the fuzzer any time by running `nim c -r tests/fuzz_recv.nim`.
