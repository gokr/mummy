## Example demonstrating large file upload support in Mummy
## Shows both traditional multipart uploads and streaming uploads
##
## ⚠️  IMPORTANT: This is a CUSTOM upload API demonstration, not a standard protocol!
##
## Standards Compliance:
## - Traditional uploads: Uses standard multipart/form-data (RFC 7578) ✅
## - Streaming uploads: Custom API (session-based with PATCH chunks) ⚠️
##
## For standards-compliant chunked uploads, use instead:
## - examples/range_upload.nim    - RFC 7233 HTTP Range Requests (standard)
## - examples/complete_upload_server.nim - TUS Protocol (industry standard)
## - examples/checksum_upload.nim - TUS with integrity verification
##
## This example is useful for:
## - Understanding Mummy's upload infrastructure
## - Custom upload API development
## - Educational purposes
##
## Use TUS or Range examples for production applications requiring standards compliance.

import ../src/mummy, ../src/mummy/routers, ../src/mummy/multipart, ../src/mummy/uploads
import std/[strformat, json, os, strutils]

proc indexHandler(request: Request) =
  ## Serve upload form
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  
  let html = """
<!DOCTYPE html>
<html>
<head>
    <title>Mummy File Upload Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .upload-area { border: 2px dashed #ccc; padding: 20px; margin: 20px 0; }
        .progress { width: 100%; height: 20px; background: #f0f0f0; margin: 10px 0; }
        .progress-bar { height: 100%; background: #4CAF50; width: 0%; }
        button { padding: 10px 20px; margin: 5px; }
        .status { margin: 10px 0; padding: 10px; background: #f9f9f9; }
    </style>
</head>
<body>
    <h1>Mummy Large File Upload Demo</h1>
    
    <div class="upload-area">
        <h3>Traditional Upload (up to 100MB)</h3>
        <form id="traditionalForm" enctype="multipart/form-data" method="post" action="/upload">
            <input type="file" name="file" required>
            <button type="submit">Upload File</button>
        </form>
    </div>
    
    <div class="upload-area">
        <h3>Streaming Upload (large files)</h3>
        <input type="file" id="streamFile">
        <button onclick="startStreamUpload()">Start Stream Upload</button>
        <button onclick="pauseUpload()">Pause</button>
        <button onclick="resumeUpload()">Resume</button>
        <button onclick="cancelUpload()">Cancel</button>
        
        <div class="progress">
            <div class="progress-bar" id="progressBar"></div>
        </div>
        <div id="status" class="status">Select a file to upload</div>
    </div>
    
    <div class="upload-area">
        <h3>Upload Statistics</h3>
        <button onclick="getStats()">Refresh Stats</button>
        <div id="stats" class="status">Click refresh to see upload statistics</div>
    </div>

    <script>
        let currentUploadId = null;
        let currentFile = null;
        let uploadPaused = false;
        
        function updateProgress(received, total) {
            const percent = total > 0 ? (received / total) * 100 : 0;
            document.getElementById('progressBar').style.width = percent + '%';
            document.getElementById('status').textContent = 
                `Uploaded: ${formatBytes(received)} / ${formatBytes(total)} (${percent.toFixed(1)}%)`;
        }
        
        function formatBytes(bytes) {
            if (bytes === 0) return '0 Bytes';
            const k = 1024;
            const sizes = ['Bytes', 'KB', 'MB', 'GB'];
            const i = Math.floor(Math.log(bytes) / Math.log(k));
            return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
        }
        
        async function startStreamUpload() {
            const fileInput = document.getElementById('streamFile');
            if (!fileInput.files.length) {
                alert('Please select a file first');
                return;
            }
            
            currentFile = fileInput.files[0];
            uploadPaused = false;
            
            try {
                // Create upload session
                const createResponse = await fetch('/upload/create', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                        filename: currentFile.name,
                        size: currentFile.size,
                        contentType: currentFile.type
                    })
                });
                
                const createResult = await createResponse.json();
                if (!createResult.success) {
                    throw new Error(createResult.error);
                }
                
                currentUploadId = createResult.uploadId;
                document.getElementById('status').textContent = 'Upload session created, starting upload...';
                
                // Start uploading chunks
                await uploadInChunks();
                
            } catch (error) {
                document.getElementById('status').textContent = 'Error: ' + error.message;
            }
        }
        
        async function uploadInChunks() {
            const chunkSize = 64 * 1024; // 64KB chunks
            let offset = 0;
            
            while (offset < currentFile.size && !uploadPaused) {
                const chunk = currentFile.slice(offset, offset + chunkSize);
                
                try {
                    const response = await fetch(`/upload/chunk/${currentUploadId}`, {
                        method: 'PATCH',
                        headers: {
                            'Content-Range': `bytes ${offset}-${offset + chunk.size - 1}/${currentFile.size}`,
                            'Content-Type': 'application/octet-stream'
                        },
                        body: chunk
                    });
                    
                    if (!response.ok) {
                        throw new Error(`Upload failed: ${response.status}`);
                    }
                    
                    offset += chunk.size;
                    updateProgress(offset, currentFile.size);
                    
                    // Small delay to prevent overwhelming the server
                    await new Promise(resolve => setTimeout(resolve, 10));
                    
                } catch (error) {
                    document.getElementById('status').textContent = 'Upload error: ' + error.message;
                    return;
                }
            }
            
            if (offset >= currentFile.size) {
                // Complete the upload
                try {
                    const response = await fetch(`/upload/complete/${currentUploadId}`, {
                        method: 'POST'
                    });
                    const result = await response.json();
                    
                    if (result.success) {
                        document.getElementById('status').textContent = 
                            `Upload completed successfully! File saved as: ${result.filename}`;
                    } else {
                        document.getElementById('status').textContent = 'Error completing upload: ' + result.error;
                    }
                } catch (error) {
                    document.getElementById('status').textContent = 'Error completing upload: ' + error.message;
                }
            }
        }
        
        function pauseUpload() {
            uploadPaused = true;
            document.getElementById('status').textContent = 'Upload paused';
        }
        
        async function resumeUpload() {
            if (!currentUploadId) {
                alert('No active upload to resume');
                return;
            }
            
            uploadPaused = false;
            
            try {
                // Get current upload status
                const response = await fetch(`/upload/status/${currentUploadId}`);
                const status = await response.json();
                
                if (status.success) {
                    updateProgress(status.bytesReceived, status.totalSize);
                    // Continue uploading from where we left off
                    await uploadInChunks();
                } else {
                    document.getElementById('status').textContent = 'Error resuming upload: ' + status.error;
                }
            } catch (error) {
                document.getElementById('status').textContent = 'Error resuming upload: ' + error.message;
            }
        }
        
        async function cancelUpload() {
            if (!currentUploadId) {
                alert('No active upload to cancel');
                return;
            }
            
            try {
                await fetch(`/upload/cancel/${currentUploadId}`, { method: 'DELETE' });
                currentUploadId = null;
                currentFile = null;
                uploadPaused = false;
                document.getElementById('progressBar').style.width = '0%';
                document.getElementById('status').textContent = 'Upload cancelled';
            } catch (error) {
                document.getElementById('status').textContent = 'Error cancelling upload: ' + error.message;
            }
        }
        
        async function getStats() {
            try {
                const response = await fetch('/upload/stats');
                const stats = await response.json();
                
                document.getElementById('stats').innerHTML = `
                    <strong>Upload Statistics:</strong><br>
                    Total uploads: ${stats.total}<br>
                    Active uploads: ${stats.active}<br>
                    Completed uploads: ${stats.completed}<br>
                    Failed uploads: ${stats.failed}
                `;
            } catch (error) {
                document.getElementById('stats').textContent = 'Error getting stats: ' + error.message;
            }
        }
    </script>
</body>
</html>
"""
  
  request.respond(200, headers, html)

proc traditionalUploadHandler(request: Request) =
  ## Handle traditional multipart file uploads
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let multipart = request.decodeMultipart()
    
    for entry in multipart:
      if entry.filename.isSome and entry.data.isSome:
        let filename = entry.filename.get()
        let (start, last) = entry.data.get()
        let fileData = request.body[start .. last]
        
        # Save file to uploads directory
        let uploadDir = "uploads"
        if not dirExists(uploadDir):
          createDir(uploadDir)
        
        let safeName = sanitizeFilename(filename)
        let filePath = uploadDir / safeName
        writeFile(filePath, fileData)
        
        let response = %*{
          "success": true,
          "message": "File uploaded successfully",
          "filename": safeName,
          "size": fileData.len
        }
        
        request.respond(200, headers, $response)
        return
    
    # No file found in multipart data
    let response = %*{
      "success": false,
      "error": "No file found in upload"
    }
    request.respond(400, headers, $response)
    
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc createUploadHandler(request: Request) =
  ## Create a new streaming upload session
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let requestBody = parseJson(request.body)
    let filename = requestBody["filename"].getStr()
    let size = requestBody["size"].getBiggestInt()
    
    let uploadId = request.createUpload(filename, size)
    
    let response = %*{
      "success": true,
      "uploadId": uploadId,
      "message": "Upload session created"
    }
    
    request.respond(200, headers, $response)
    
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc uploadChunkHandler(request: Request) =
  ## Handle streaming upload chunks
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let uploadId = request.pathParams["uploadId"]
    let upload = request.getUpload(uploadId)
    
    if upload == nil:
      let response = %*{
        "success": false,
        "error": "Upload session not found"
      }
      request.respond(404, headers, $response)
      return
    
    # Write chunk data to upload
    upload[].writeChunk(request.body.toOpenArrayByte(0, request.body.len - 1))
    
    let response = %*{
      "success": true,
      "bytesReceived": upload[].bytesReceived,
      "totalSize": upload[].totalSize
    }
    
    request.respond(200, headers, $response)
    
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc completeUploadHandler(request: Request) =
  ## Complete a streaming upload
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let uploadId = request.pathParams["uploadId"]
    let upload = request.getUpload(uploadId)
    
    if upload == nil:
      let response = %*{
        "success": false,
        "error": "Upload session not found"
      }
      request.respond(404, headers, $response)
      return
    
    # Complete the upload
    upload[].completeUpload()
    
    let response = %*{
      "success": true,
      "filename": upload[].filename,
      "finalPath": upload[].finalPath,
      "size": upload[].bytesReceived
    }
    
    request.respond(200, headers, $response)
    
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc uploadStatusHandler(request: Request) =
  ## Get upload status
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let uploadId = request.pathParams["uploadId"]
    let upload = request.getUpload(uploadId)
    
    if upload == nil:
      let response = %*{
        "success": false,
        "error": "Upload session not found"
      }
      request.respond(404, headers, $response)
      return
    
    let response = %*{
      "success": true,
      "uploadId": uploadId,
      "filename": upload[].filename,
      "bytesReceived": upload[].bytesReceived,
      "totalSize": upload[].totalSize,
      "status": $upload[].status,
      "progress": upload[].getUploadProgress()
    }
    
    request.respond(200, headers, $response)
    
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc cancelUploadHandler(request: Request) =
  ## Cancel an upload
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    let uploadId = request.pathParams["uploadId"]
    let upload = request.getUpload(uploadId)
    
    if upload == nil:
      let response = %*{
        "success": false,
        "error": "Upload session not found"
      }
      request.respond(404, headers, $response)
      return
    
    upload[].cancelUpload()
    
    let response = %*{
      "success": true,
      "message": "Upload cancelled"
    }
    
    request.respond(200, headers, $response)
    
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

proc uploadStatsHandler(request: Request) =
  ## Get upload statistics
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  # Try to get an upload to check if uploads are enabled
  let testUpload = request.getUpload("non-existent-id")
  # If we get here without error, uploads are enabled
  
  let response = %*{
    "total": 0,
    "active": 0,
    "completed": 0,
    "failed": 0,
    "message": "Upload statistics not directly accessible from examples"
  }
  
  request.respond(200, headers, $response)

# Set up router
var router: Router
router.get("/", indexHandler)
router.post("/upload", traditionalUploadHandler)
router.post("/upload/create", createUploadHandler)
router.patch("/upload/chunk/*uploadId", uploadChunkHandler)
router.post("/upload/complete/*uploadId", completeUploadHandler)
router.head("/upload/status/*uploadId", uploadStatusHandler)
router.get("/upload/status/*uploadId", uploadStatusHandler)
router.delete("/upload/cancel/*uploadId", cancelUploadHandler)
router.get("/upload/stats", uploadStatsHandler)

# Configure upload settings
var uploadConfig = defaultUploadConfig()
uploadConfig.uploadDir = "uploads"
uploadConfig.tempDir = "uploads/tmp"
uploadConfig.maxFileSize = 1024 * 1024 * 1024  # 1GB max
uploadConfig.maxConcurrentUploads = 5
uploadConfig.uploadTimeout = 1800.0  # 30 minutes

# Create server with upload support enabled
let server = newServer(
  router,
  enableUploads = true,
  uploadConfig = uploadConfig,
  maxBodyLen = 100 * 1024 * 1024  # 100MB for traditional uploads
)

echo "File Upload Demo Server"
echo "======================="
echo "Traditional uploads: Up to 100MB via multipart forms"
echo "Streaming uploads: Up to 1GB with pause/resume support"
echo "Upload directory: uploads/"
echo "Serving on http://localhost:8080"
echo ""

server.serve(Port(8080))