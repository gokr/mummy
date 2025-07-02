## HTTP Range request upload example
## Demonstrates RFC 7233 compliant partial content uploads using PATCH method
##
## 📋 STANDARDS COMPLIANT: RFC 7233 HTTP Range Requests ✅
##
## This example implements the official HTTP Range Request standard:
## - RFC 7233: Hypertext Transfer Protocol (HTTP/1.1): Range Requests
## - Uses standard Content-Range headers
## - PATCH method with precise byte positioning
## - Compatible with HTTP caches and proxies
## - Widely supported by browsers and servers
##
## Use this for:
## - Standards-compliant resumable uploads
## - Integration with existing HTTP infrastructure
## - Applications requiring HTTP Range Request compatibility
## - Browser-based chunked uploads with pause/resume
##
## Features:
## - 64KB chunks for efficient transfer
## - Precise byte-range positioning
## - Pause/resume functionality
## - Progress tracking
## - Compatible with HTTP/1.1 standard

import ../src/mummy, ../src/mummy/routers, ../src/mummy/ranges
import std/[strformat, json, os, strutils, times]

proc indexHandler(request: Request) =
  ## Serve Range upload demo page
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  
  let html = """
<!DOCTYPE html>
<html>
<head>
    <title>HTTP Range Upload Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .upload-area { border: 2px dashed #ccc; padding: 20px; margin: 20px 0; }
        .progress { width: 100%; height: 20px; background: #f0f0f0; margin: 10px 0; }
        .progress-bar { height: 100%; background: #4CAF50; transition: width 0.3s; }
        button { padding: 10px 20px; margin: 5px; }
        .status { margin: 10px 0; padding: 10px; background: #f9f9f9; }
        .info { background: #e8f5e8; padding: 10px; margin: 10px 0; }
        .log { background: #f8f8f8; padding: 10px; margin: 10px 0; font-family: monospace; font-size: 12px; max-height: 200px; overflow-y: auto; }
    </style>
</head>
<body>
    <h1>HTTP Range Upload Demo</h1>
    <p>This demo shows RFC 7233 compliant Range request uploads using PATCH method.</p>
    
    <div class="info">
        <strong>How it works:</strong>
        <ul>
            <li>File is divided into 64KB chunks</li>
            <li>Each chunk is uploaded using PATCH with Content-Range header</li>
            <li>Server validates range positions and assembles the file</li>
            <li>Upload can be paused and resumed by continuing from current position</li>
        </ul>
    </div>
    
    <div class="upload-area">
        <input type="file" id="fileInput" onchange="resetUpload()">
        <br><br>
        <button onclick="startUpload()" id="startBtn">Start Upload</button>
        <button onclick="pauseUpload()" id="pauseBtn" disabled>Pause</button>
        <button onclick="resumeUpload()" id="resumeBtn" disabled>Resume</button>
        <button onclick="abortUpload()" id="abortBtn" disabled>Abort</button>
        
        <div class="progress">
            <div class="progress-bar" id="progressBar" style="width: 0%"></div>
        </div>
        <div id="status" class="status">Select a file to upload</div>
    </div>
    
    <div class="log" id="log"></div>

    <script>
        let uploadId = null;
        let file = null;
        let currentOffset = 0;
        let isPaused = false;
        const chunkSize = 64 * 1024; // 64KB chunks
        
        function log(message) {
            const logDiv = document.getElementById('log');
            logDiv.innerHTML += new Date().toLocaleTimeString() + ': ' + message + '<br>';
            logDiv.scrollTop = logDiv.scrollHeight;
        }
        
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        function updateButtons(uploading, paused) {
            document.getElementById('startBtn').disabled = uploading && !paused;
            document.getElementById('pauseBtn').disabled = !uploading || paused;
            document.getElementById('resumeBtn').disabled = !uploading || !paused;
            document.getElementById('abortBtn').disabled = !uploading;
        }
        
        function resetUpload() {
            file = document.getElementById('fileInput').files[0];
            uploadId = null;
            currentOffset = 0;
            isPaused = false;
            document.getElementById('progressBar').style.width = '0%';
            document.getElementById('status').textContent = 'File selected, ready for Range upload';
            updateButtons(false, false);
        }
        
        async function createUpload() {
            try {
                const response = await fetch('/range/create', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        filename: file.name,
                        size: file.size
                    })
                });
                
                const result = await response.json();
                if (result.success) {
                    uploadId = result.uploadId;
                    log(`Upload session created: ${uploadId}`);
                    return true;
                } else {
                    log(`Error creating upload: ${result.error}`);
                    return false;
                }
            } catch (error) {
                log(`Error creating upload: ${error.message}`);
                return false;
            }
        }
        
        async function uploadChunk() {
            if (isPaused || currentOffset >= file.size) {
                return false;
            }
            
            const end = Math.min(currentOffset + chunkSize - 1, file.size - 1);
            const chunk = file.slice(currentOffset, end + 1);
            
            try {
                const response = await fetch(`/range/upload/${uploadId}`, {
                    method: 'PATCH',
                    headers: {
                        'Content-Range': `bytes ${currentOffset}-${end}/${file.size}`,
                        'Content-Type': 'application/octet-stream'
                    },
                    body: chunk
                });
                
                if (response.ok) {
                    currentOffset = end + 1;
                    const percentage = (currentOffset / file.size * 100).toFixed(2);
                    document.getElementById('progressBar').style.width = percentage + '%';
                    document.getElementById('status').textContent = 
                        `Uploading: ${formatBytes(currentOffset)} / ${formatBytes(file.size)} (${percentage}%)`;
                    
                    log(`Uploaded chunk: bytes ${currentOffset - chunk.size}-${end} (${formatBytes(chunk.size)})`);
                    return true;
                } else {
                    log(`Chunk upload failed: ${response.status} ${response.statusText}`);
                    return false;
                }
            } catch (error) {
                log(`Chunk upload error: ${error.message}`);
                return false;
            }
        }
        
        async function uploadFile() {
            updateButtons(true, false);
            
            while (currentOffset < file.size && !isPaused) {
                const success = await uploadChunk();
                if (!success) {
                    log('Upload failed, stopping');
                    updateButtons(false, false);
                    return;
                }
                
                // Small delay between chunks
                await new Promise(resolve => setTimeout(resolve, 50));
            }
            
            if (currentOffset >= file.size) {
                log('Range upload completed successfully!');
                document.getElementById('status').textContent = 'Upload completed!';
                updateButtons(false, false);
            } else if (isPaused) {
                log('Upload paused');
                document.getElementById('status').textContent = 'Upload paused';
                updateButtons(true, true);
            }
        }
        
        async function startUpload() {
            if (!file) {
                alert('Please select a file first');
                return;
            }
            
            log(`Starting Range upload: ${file.name} (${formatBytes(file.size)})`);
            
            if (!uploadId) {
                const success = await createUpload();
                if (!success) return;
            }
            
            isPaused = false;
            uploadFile();
        }
        
        function pauseUpload() {
            isPaused = true;
        }
        
        function resumeUpload() {
            isPaused = false;
            uploadFile();
        }
        
        function abortUpload() {
            isPaused = true;
            uploadId = null;
            currentOffset = 0;
            log('Upload aborted');
            document.getElementById('status').textContent = 'Upload aborted';
            document.getElementById('progressBar').style.width = '0%';
            updateButtons(false, false);
        }
        
        // Initial state
        updateButtons(false, false);
        log('Range upload client ready');
        log('RFC 7233 compliant partial content uploads');
    </script>
</body>
</html>
"""
  
  request.respond(200, headers, html)

proc createRangeUpload(request: Request) =
  ## Create a new range upload session
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let requestBody = parseJson(request.body)
    let filename = requestBody["filename"].getStr()
    let size = requestBody["size"].getBiggestInt()
    
    let uploadId = request.createUpload(filename, size)
    let upload = request.getUpload(uploadId)
    
    if upload != nil:
      upload[].setRangeSupport(true)
      
      let response = %*{
        "success": true,
        "uploadId": uploadId
      }
      request.respond(200, headers, $response)
    else:
      let response = %*{
        "success": false,
        "error": "Failed to create upload"
      }
      request.respond(500, headers, $response)
      
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc rangeUploadHandler(request: Request) =
  ## Handle range upload PATCH requests
  let uploadId = request.pathParams["uploadId"]
  # Get Content-Range header
  var contentRange = ""
  for (key, value) in request.headers:
    if key.toLowerAscii() == "content-range":
      contentRange = value
      break
  
  if contentRange.len > 0:
    request.handleRangeRequest(uploadId, contentRange)
  else:
    request.respond(400, emptyHttpHeaders(), "Content-Range header required")

# Router setup
var router: Router
router.get("/", indexHandler)
router.post("/range/create", createRangeUpload)
router.patch("/range/upload/@uploadId", rangeUploadHandler)

# Configure upload settings
var uploadConfig = defaultUploadConfig()
uploadConfig.uploadDir = "uploads"
uploadConfig.tempDir = "uploads/tmp"
uploadConfig.maxFileSize = 1024 * 1024 * 1024  # 1GB
uploadConfig.enableRangeRequests = true

# Create server with range upload support
let server = newServer(
  router,
  enableUploads = true,
  uploadConfig = uploadConfig,
  maxBodyLen = 100 * 1024 * 1024  # 100MB for chunk uploads
)

echo "HTTP Range Upload Server"
echo "======================="
echo "Protocol: RFC 7233 Range Requests"
echo "Method: PATCH with Content-Range headers"
echo "Max file size: 1GB"
echo "Chunk size: 64KB"
echo "Upload directory: uploads/"
echo "Features: pause, resume, precise positioning"
echo "Serving on http://localhost:8080"

server.serve(Port(8080))