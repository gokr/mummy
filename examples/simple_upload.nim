## Simple file upload example for Mummy
## Demonstrates basic streaming upload functionality
##
## ⚠️  EDUCATIONAL EXAMPLE: Custom streaming API (not standards-compliant)
##
## This example shows Mummy's upload infrastructure capabilities but
## does NOT implement standard protocols. It's for learning purposes.
##
## For production applications, use standards-compliant examples:
## ✅ examples/tus_upload.nim - TUS Protocol 1.0 (industry standard)
## ✅ examples/range_upload.nim - RFC 7233 HTTP Range Requests  
## ✅ examples/basic_upload.nim - RFC 7578 Multipart form uploads
##
## This example demonstrates:
## - Mummy's streaming upload capabilities
## - Custom upload session management
## - Educational upload workflow
##
## Use this for:
## - Understanding Mummy's upload infrastructure
## - Learning streaming upload concepts
## - Prototyping custom upload solutions
##
## ⚠️  Not recommended for production use - use standards-compliant examples instead

import ../src/mummy, ../src/mummy/routers
import std/[strformat, os, strutils]

proc uploadHandler(request: Request) =
  ## Handle file uploads with automatic streaming for large files
  case request.httpMethod:
  of "POST":
    # Create new upload
    # Extract filename from headers
    var filename = "upload.bin"
    for (key, value) in request.headers:
      if key.toLowerAscii() == "x-filename":
        filename = value
        break
    
    # Extract content length
    var contentLength: int64 = 0
    for (key, value) in request.headers:
      if key.toLowerAscii() == "content-length":
        try:
          contentLength = value.parseBiggestInt()
        except:
          discard
        break
    
    echo fmt"Starting upload: {filename} ({contentLength} bytes)"
    
    try:
      let uploadId = request.createUpload(filename, contentLength)
      let upload = request.getUpload(uploadId)
      
      if upload != nil:
        # Set up progress callback
        upload[].onProgress = proc(bytesReceived: int64, totalBytes: int64) =
          let progress = if totalBytes > 0: (bytesReceived.float / totalBytes.float) * 100.0 else: 0.0
          echo fmt"Upload progress: {bytesReceived} / {totalBytes} bytes ({progress:.1f}%)"
        
        upload[].onComplete = proc(finalPath: string) =
          echo fmt"Upload completed: {finalPath}"
        
        upload[].onError = proc(error: string) =
          echo fmt"Upload error: {error}"
        
        # Open file for writing
        upload[].openForWriting()
        
        # Write the request body (for small uploads this works directly)
        if request.body.len > 0:
          upload[].writeChunk(request.body.toOpenArrayByte(0, request.body.len - 1))
        
        # Complete the upload
        upload[].completeUpload()
        
        var headers: HttpHeaders
        headers["Content-Type"] = "text/plain"
        request.respond(200, headers, fmt"Upload successful: {upload[].finalPath}")
      else:
        request.respond(500, emptyHttpHeaders(), "Failed to create upload session")
    except Exception as e:
      request.respond(500, emptyHttpHeaders(), fmt"Upload error: {e.msg}")
  
  else:
    # Show upload form
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html"
    
    let html = """
<!DOCTYPE html>
<html>
<head>
    <title>Simple Upload</title>
</head>
<body>
    <h1>Simple File Upload</h1>
    <form method="post" enctype="multipart/form-data">
        <input type="file" name="file" required>
        <button type="submit">Upload</button>
    </form>
    
    <h2>JavaScript Upload (with progress)</h2>
    <input type="file" id="fileInput">
    <button onclick="uploadFile()">Upload with Progress</button>
    <div id="progress"></div>
    
    <script>
        async function uploadFile() {
            const fileInput = document.getElementById('fileInput');
            const file = fileInput.files[0];
            if (!file) {
                alert('Please select a file');
                return;
            }
            
            const progressDiv = document.getElementById('progress');
            
            try {
                const response = await fetch('/upload', {
                    method: 'POST',
                    headers: {
                        'X-Filename': file.name,
                        'Content-Type': 'application/octet-stream',
                        'Content-Length': file.size.toString()
                    },
                    body: file
                });
                
                const result = await response.text();
                progressDiv.innerHTML = '<p>Upload result: ' + result + '</p>';
                
            } catch (error) {
                progressDiv.innerHTML = '<p>Error: ' + error.message + '</p>';
            }
        }
    </script>
</body>
</html>
"""
    
    request.respond(200, headers, html)

# Set up simple router
var router: Router
router.get("/", uploadHandler)
router.post("/", uploadHandler)
router.get("/upload", uploadHandler)
router.post("/upload", uploadHandler)

# Configure for large uploads
var uploadConfig = defaultUploadConfig()
uploadConfig.uploadDir = "uploads"
uploadConfig.tempDir = "uploads/tmp"
uploadConfig.maxFileSize = 500 * 1024 * 1024  # 500MB max

# Create server with uploads enabled
let server = newServer(
  router,
  enableUploads = true,
  uploadConfig = uploadConfig,
  maxBodyLen = 100 * 1024 * 1024  # 100MB for in-memory processing
)

echo "Simple Upload Server"
echo "==================="
echo "Upload directory: uploads/"
echo "Max file size: 500MB"
echo "Max in-memory: 100MB (larger files will stream to disk)"
echo "Serving on http://localhost:8080"

server.serve(Port(8080))