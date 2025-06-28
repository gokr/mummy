## Simple SSE example with continuous streaming
## This demonstrates real-time SSE updates without complex threading

import ../src/mummy, ../src/mummy/routers
import std/[times, strutils, options, os]

proc handleSSE(request: Request) =
  echo "Starting SSE connection for: ", request.remoteAddress
  
  let connection = request.respondSSE()
  
  # Send initial welcome event
  connection.send(SSEEvent(
    event: some("welcome"),
    data: """{"message": "SSE connection established", "timestamp": """ & $now() & """}""",
    id: some("welcome-1")
  ))
  
  # Send a series of updates to demonstrate continuous streaming
  # In a real application, this would be driven by business events
  for i in 1..10:
    if connection.active:
      connection.send(SSEEvent(
        event: some("update"),
        data: """{"counter": """ & $i & """, "timestamp": """ & $now() & """, "message": "Streaming update #""" & $i & """"}""",
        id: some("update-" & $i)
      ))
      echo "Sent update #", i, " to client ", connection.clientId
      
      # Small delay between updates to show streaming effect
      # Note: In production, you wouldn't use sleep in request handlers
      # Instead, updates would be triggered by external events
      if i < 10:
        sleep(1000)
    else:
      echo "Connection became inactive, stopping updates"
      break
  
  # Send final event
  if connection.active:
    connection.send(SSEEvent(
      event: some("complete"),
      data: """{"message": "Streaming complete", "timestamp": """ & $now() & """}""",
      id: some("complete-1")
    ))
  
  echo "Finished sending updates to client ", connection.clientId

proc handleRoot(request: Request) =
  let html = """
<!DOCTYPE html>
<html>
<head>
    <title>SSE Streaming Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        #messages { border: 1px solid #ccc; padding: 10px; height: 400px; overflow-y: auto; background: #f9f9f9; }
        .welcome { color: green; font-weight: bold; }
        .update { color: blue; margin: 5px 0; }
        .complete { color: red; font-weight: bold; }
        .timestamp { color: #666; font-size: 0.9em; }
        #status { margin: 10px 0; padding: 10px; background: #f0f0f0; border-radius: 5px; }
        button { padding: 10px 20px; margin: 5px; font-size: 16px; }
    </style>
</head>
<body>
    <h1>SSE Streaming Demo</h1>
    <p>This demonstrates Server-Sent Events with continuous streaming. Each connection will receive 10 updates over 10 seconds.</p>
    
    <div id="status">Click "Start New Stream" to begin receiving real-time updates...</div>
    <button onclick="startNewStream()">Start New Stream</button>
    <button onclick="clearMessages()">Clear Messages</button>
    
    <div id="messages"></div>
    
    <script>
        let eventSource = null;
        const messagesDiv = document.getElementById('messages');
        const statusDiv = document.getElementById('status');
        
        function startNewStream() {
            // Close existing connection if any
            if (eventSource) {
                eventSource.close();
            }
            
            // Clear messages
            messagesDiv.innerHTML = '';
            statusDiv.textContent = 'Connecting to SSE stream...';
            statusDiv.style.background = '#fff3cd';
            
            // Start new SSE connection
            eventSource = new EventSource('/events');
            
            eventSource.onopen = function() {
                statusDiv.textContent = 'Connected! Receiving real-time updates...';
                statusDiv.style.background = '#d4edda';
            };
            
            eventSource.onerror = function() {
                statusDiv.textContent = 'Stream ended or connection error.';
                statusDiv.style.background = '#f8d7da';
            };
            
            eventSource.onmessage = function(event) {
                addMessage('default', event.data);
            };
            
            eventSource.addEventListener('welcome', function(event) {
                addMessage('welcome', event.data, 'Welcome');
            });
            
            eventSource.addEventListener('update', function(event) {
                addMessage('update', event.data, 'Update');
            });
            
            eventSource.addEventListener('complete', function(event) {
                addMessage('complete', event.data, 'Complete');
                statusDiv.textContent = 'Stream completed successfully!';
                statusDiv.style.background = '#d1ecf1';
            });
        }
        
        function addMessage(type, data, prefix = '') {
            const div = document.createElement('div');
            div.className = type;
            const timestamp = new Date().toLocaleTimeString();
            const prefixText = prefix ? prefix + ': ' : '';
            div.innerHTML = '<span class="timestamp">' + timestamp + '</span> ' + prefixText + data;
            messagesDiv.appendChild(div);
            messagesDiv.scrollTop = messagesDiv.scrollHeight;
        }
        
        function clearMessages() {
            messagesDiv.innerHTML = '';
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
  
  let server = newServer(router)
  echo "SSE Streaming Demo at http://localhost:8080"
  echo "- Open http://localhost:8080 in your browser"
  echo "- Click 'Start New Stream' to see real-time updates"
  echo "- Each stream sends 10 updates over 10 seconds"
  server.serve(Port(8080))

when isMainModule:
  main()
