## Simple Server-Sent Events (SSE) example for Mummy
## This demonstrates real-time streaming capabilities using the new SSE API

import ../src/mummy, ../src/mummy/routers
import std/[json, times, strutils, options, locks]

# Thread-safe SSE connections storage
var connectionsLock: Lock
var activeConnections: seq[SSEConnection] = @[]
initLock(connectionsLock)

proc handleSSEEndpoint(request: Request) =
  echo "New SSE connection from: ", request.remoteAddress

  let connection = request.respondSSE()
  {.gcsafe.}:
    withLock connectionsLock:
      activeConnections.add(connection)

  # Send welcome message
  connection.send(SSEEvent(
    event: some("connected"),
    data: """{"message": "Connected to SSE stream", "timestamp": """ & $now() & """}""",
    id: some("welcome")
  ))

proc handleBroadcast(request: Request) =
  # Parse JSON body for broadcast message
  try:
    let jsonData = parseJson(request.body)
    let message = jsonData["message"].getStr()
    let eventType = jsonData.getOrDefault("event").getStr("broadcast")

    # Broadcast to all active connections
    let event = SSEEvent(
      event: some(eventType),
      data: """{"message": """ & escapeJson(message) & """, "timestamp": """ & $now() & """}""",
      id: some("msg-" & $now().toTime().toUnix())
    )

    {.gcsafe.}:
      withLock connectionsLock:
        for connection in activeConnections:
          if connection.active:
            connection.send(event)

    request.respond(200, @[("Content-Type", "application/json")], """{"status": "broadcasted"}""")
  except:
    request.respond(400, @[("Content-Type", "application/json")], """{"error": "Invalid JSON"}""")

proc handleStatus(request: Request) =
  var activeCount: int
  {.gcsafe.}:
    withLock connectionsLock:
      activeCount = activeConnections.len
  let response = """{"active_connections": """ & $activeCount & """, "timestamp": """" & $now() & """"}"""
  request.respond(200, @[("Content-Type", "application/json")], response)

proc handleRoot(request: Request) {.gcsafe.} =
  # Serve a simple HTML page for testing SSE
  let html = """
<!DOCTYPE html>
<html>
<head>
    <title>Mummy SSE Example</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        #messages { border: 1px solid #ccc; height: 400px; overflow-y: scroll; padding: 10px; margin: 20px 0; }
        .message { margin: 5px 0; padding: 5px; background: #f0f0f0; border-radius: 3px; }
        .event-type { font-weight: bold; color: #0066cc; }
        button { padding: 10px 20px; margin: 5px; }
        input[type="text"] { padding: 8px; width: 300px; }
    </style>
</head>
<body>
    <h1>Mummy Server-Sent Events (SSE) Demo</h1>
    
    <div>
        <button onclick="connect()">Connect to SSE Stream</button>
        <button onclick="disconnect()">Disconnect</button>
        <span id="status">Disconnected</span>
    </div>
    
    <div>
        <input type="text" id="messageInput" placeholder="Enter message to broadcast" value="Hello from browser!">
        <button onclick="broadcast()">Broadcast Message</button>
        <button onclick="getStatus()">Get Server Status</button>
    </div>
    
    <div id="messages"></div>
    
    <script>
        let eventSource = null;
        
        function connect() {
            if (eventSource) {
                eventSource.close();
            }
            
            eventSource = new EventSource('/events');
            document.getElementById('status').textContent = 'Connecting...';
            
            eventSource.onopen = function(event) {
                document.getElementById('status').textContent = 'Connected';
                addMessage('System', 'Connected to SSE stream', 'info');
            };
            
            eventSource.onmessage = function(event) {
                try {
                    const data = JSON.parse(event.data);
                    addMessage('Message', data.message, 'message');
                } catch (e) {
                    addMessage('Raw', event.data, 'raw');
                }
            };
            
            eventSource.addEventListener('connected', function(event) {
                try {
                    const data = JSON.parse(event.data);
                    addMessage('Connected', data.message, 'connected');
                } catch (e) {
                    addMessage('Connected', event.data, 'connected');
                }
            });
            
            eventSource.addEventListener('broadcast', function(event) {
                try {
                    const data = JSON.parse(event.data);
                    addMessage('Broadcast', data.message, 'broadcast');
                } catch (e) {
                    addMessage('Broadcast', event.data, 'broadcast');
                }
            });
            
            eventSource.onerror = function(event) {
                document.getElementById('status').textContent = 'Error/Disconnected';
                addMessage('System', 'Connection error or closed', 'error');
            };
        }
        
        function disconnect() {
            if (eventSource) {
                eventSource.close();
                eventSource = null;
                document.getElementById('status').textContent = 'Disconnected';
                addMessage('System', 'Disconnected from SSE stream', 'info');
            }
        }
        
        function addMessage(type, message, className) {
            const messagesDiv = document.getElementById('messages');
            const messageDiv = document.createElement('div');
            messageDiv.className = 'message ' + className;
            messageDiv.innerHTML = '<span class="event-type">[' + type + ']</span> ' + 
                                 new Date().toLocaleTimeString() + ': ' + message;
            messagesDiv.appendChild(messageDiv);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }
        
        function broadcast() {
            const message = document.getElementById('messageInput').value;
            if (!message) return;
            
            fetch('/broadcast', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                    message: message,
                    event: 'broadcast'
                })
            })
            .then(response => response.json())
            .then(data => {
                addMessage('Local', 'Broadcast sent: ' + message, 'info');
                document.getElementById('messageInput').value = '';
            })
            .catch(error => {
                addMessage('Error', 'Failed to broadcast: ' + error, 'error');
            });
        }
        
        function getStatus() {
            fetch('/status')
            .then(response => response.json())
            .then(data => {
                addMessage('Status', 'Active connections: ' + data.active_connections, 'info');
            })
            .catch(error => {
                addMessage('Error', 'Failed to get status: ' + error, 'error');
            });
        }
        
        // Auto-connect on page load
        window.onload = function() {
            connect();
        };
    </script>
</body>
</html>
"""
  request.respond(200, @[("Content-Type", "text/html")], html)

proc main() =
  echo "Starting Mummy SSE example server..."
  
  var router = Router()
  
  # Routes
  router.get("/", handleRoot)
  router.get("/events", handleSSEEndpoint)
  router.post("/broadcast", handleBroadcast)
  router.get("/status", handleStatus)
  
  let server = newServer(router)
  
  echo "Server running at http://localhost:8080"
  echo "Open http://localhost:8080 in your browser to test SSE"
  echo "Press Ctrl+C to stop"
  
  server.serve(Port(8080))

when isMainModule:
  main()