## Minimal Server-Sent Events (SSE) example for Mummy
## This demonstrates basic SSE capabilities

import ../src/mummy, ../src/mummy/routers
import std/[json, times, strutils, options, os, sequtils, locks]

# Global storage for active connections  
var L: Lock
var activeConnections: seq[SSEConnection] = @[]
initLock(L)

proc handleSSE(request: Request) {.gcsafe.} =
  echo "Starting SSE connection for: ", request.remoteAddress

  let connection = request.respondSSE()
  {.gcsafe.}:
    withLock L:
      activeConnections.add(connection)

  # Send initial welcome event
  connection.send(SSEEvent(
    event: some("welcome"),
    data: """{"message": "SSE connection established", "timestamp": """ & $now() & """}""",
    id: some("welcome-1")
  ))

  echo "SSE connection established for client ", connection.clientId

# Endpoint to manually trigger updates (for demonstration)
proc handleTriggerUpdate(request: Request) {.gcsafe.} =
  var sentCount = 0
  let timestamp = $now()

  # Send update to all active connections
  {.gcsafe.}:
    withLock L:
      for connection in activeConnections:
        if connection.active:
          connection.send(SSEEvent(
            event: some("manual_update"),
            data: """{"timestamp": """ & timestamp & """, "message": "Manual update triggered", "type": "manual"}""",
            id: some("manual-" & $now().toTime().toUnix())
          ))
          inc sentCount

      # Clean up inactive connections
      activeConnections = activeConnections.filter(proc(conn: SSEConnection): bool = conn.active)

  var connectionCount: int
  {.gcsafe.}:
    withLock L:
      connectionCount = activeConnections.len
  request.respond(200, @[("Content-Type", "application/json")],
                 """{"sent_to": """ & $sentCount & """, "active_connections": """ & $connectionCount & """}""")

# Endpoint to send periodic updates
proc handleStartUpdates(request: Request) {.gcsafe.} =
  var sentCount = 0

  # Send 5 updates with 1 second delay between them
  for i in 1..5:
    let timestamp = $now()
    {.gcsafe.}:
      withLock L:
        for connection in activeConnections:
          if connection.active:
            connection.send(SSEEvent(
              event: some("auto_update"),
              data: """{"timestamp": """ & timestamp & """, "counter": """ & $i & """, "message": "Auto update #""" & $i & """", "type": "automatic"}""",
              id: some("auto-" & $i)
            ))
            inc sentCount

    if i < 5: # Don't sleep after the last update
      sleep(1000)

  # Clean up inactive connections
  {.gcsafe.}:
    withLock L:
      activeConnections = activeConnections.filter(proc(conn: SSEConnection): bool = conn.active)

  var connectionCount: int
  {.gcsafe.}:
    withLock L:
      connectionCount = activeConnections.len
  request.respond(200, @[("Content-Type", "application/json")],
                 """{"updates_sent": 5, "total_events": """ & $sentCount & """, "active_connections": """ & $connectionCount & """}""")

proc handleRoot(request: Request) {.gcsafe.} =
  let html = """
<!DOCTYPE html>
<html>
<head>
    <title>Simple SSE Test - Real-time Updates</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        #messages { border: 1px solid #ccc; padding: 10px; height: 400px; overflow-y: auto; }
        .welcome { color: green; font-weight: bold; }
        .update { color: blue; }
        .timestamp { color: #666; font-size: 0.9em; }
        #status { margin: 10px 0; padding: 10px; background: #f0f0f0; }
    </style>
</head>
<body>
    <h1>Simple SSE Test - Real-time Updates</h1>
    <div id="status">Connecting to SSE stream...</div>
    <div style="margin: 10px 0;">
        <button onclick="triggerUpdate()">Send Manual Update</button>
        <button onclick="startAutoUpdates()">Send 5 Auto Updates</button>
    </div>
    <div id="messages"></div>
    <script>
        const eventSource = new EventSource('/events');
        const messagesDiv = document.getElementById('messages');
        const statusDiv = document.getElementById('status');

        eventSource.onopen = function() {
            statusDiv.textContent = 'Connected! Receiving real-time updates every 2 seconds...';
            statusDiv.style.background = '#d4edda';
        };

        eventSource.onerror = function() {
            statusDiv.textContent = 'Connection error or closed.';
            statusDiv.style.background = '#f8d7da';
        };

        eventSource.onmessage = function(event) {
            const div = document.createElement('div');
            div.innerHTML = '<span class="timestamp">' + new Date().toLocaleTimeString() + '</span>: ' + event.data;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        };

        eventSource.addEventListener('welcome', function(event) {
            const div = document.createElement('div');
            div.className = 'welcome';
            div.innerHTML = '<span class="timestamp">' + new Date().toLocaleTimeString() + '</span> Welcome: ' + event.data;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        });

        eventSource.addEventListener('update', function(event) {
            const div = document.createElement('div');
            div.className = 'update';
            div.innerHTML = '<span class="timestamp">' + new Date().toLocaleTimeString() + '</span> Update: ' + event.data;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        });

        eventSource.addEventListener('manual_update', function(event) {
            const div = document.createElement('div');
            div.className = 'update';
            div.style.background = '#fff3cd';
            div.innerHTML = '<span class="timestamp">' + new Date().toLocaleTimeString() + '</span> Manual: ' + event.data;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        });

        eventSource.addEventListener('auto_update', function(event) {
            const div = document.createElement('div');
            div.className = 'update';
            div.style.background = '#d1ecf1';
            div.innerHTML = '<span class="timestamp">' + new Date().toLocaleTimeString() + '</span> Auto: ' + event.data;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        });

        function triggerUpdate() {
            fetch('/trigger', { method: 'POST' })
                .then(response => response.json())
                .then(data => console.log('Manual update triggered:', data));
        }

        function startAutoUpdates() {
            fetch('/auto', { method: 'POST' })
                .then(response => response.json())
                .then(data => console.log('Auto updates started:', data));
        }
    </script>
</body>
</html>
"""
  request.respond(200, @[("Content-Type", "text/html")], html)

proc main() =
  var router = Router()
  router.get("/", handleRoot)
  router.get("/events", handleSSE)
  router.post("/trigger", handleTriggerUpdate)
  router.post("/auto", handleStartUpdates)

  let server = newServer(router)
  echo "Simple SSE server at http://localhost:8080"
  echo "- Open http://localhost:8080 in your browser"
  echo "- Click buttons to trigger real-time updates"
  server.serve(Port(8080))

when isMainModule:
  main()