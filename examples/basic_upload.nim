## Basic file upload example for Mummy
## Simple demonstration without streaming - just basic file saving
##
## 📋 STANDARDS COMPLIANT: Multipart Form Data (RFC 7578) ✅
##
## This example implements the standard HTTP multipart upload:
## - RFC 7578: Returning Values from Forms: multipart/form-data
## - Standard HTML form file uploads
## - Compatible with all browsers and HTTP clients
## - Simple, traditional approach
##
## Use this for:
## - Basic file upload functionality
## - HTML form-based uploads
## - Simple applications without chunking requirements
## - Learning basic upload handling
## - Small to medium file uploads (under server limits)
##
## Features:
## - Standard HTML form compatibility
## - Direct file saving
## - Simple error handling
## - Minimal complexity
##
## For large files or resumable uploads, see:
## - examples/tus_upload.nim (TUS protocol)
## - examples/range_upload.nim (HTTP Range requests)

import ../src/mummy, ../src/mummy/routers, ../src/mummy/multipart
import std/[strformat, os, strutils]

proc uploadHandler(request: Request) =
  ## Handle basic file uploads
  case request.httpMethod:
  of "POST":
    # Handle multipart upload
    try:
      let multipart = request.decodeMultipart()
      
      for entry in multipart:
        if entry.filename.isSome and entry.data.isSome:
          let filename = entry.filename.get()
          let (start, last) = entry.data.get()
          let fileData = request.body[start .. last]
          
          # Create upload directory
          let uploadDir = "uploads"
          if not dirExists(uploadDir):
            createDir(uploadDir)
          
          # Sanitize filename
          let safeName = filename.replace("/", "_").replace("\\", "_").replace("..", "_")
          let filePath = uploadDir / safeName
          
          # Save file
          writeFile(filePath, fileData)
          
          echo fmt"File uploaded: {safeName} ({fileData.len} bytes)"
          
          var headers: HttpHeaders
          headers["Content-Type"] = "text/plain"
          request.respond(200, headers, fmt"Upload successful: {safeName} ({fileData.len} bytes)")
          return
      
      # No file found
      request.respond(400, emptyHttpHeaders(), "No file found in upload")
      
    except Exception as e:
      echo fmt"Upload error: {e.msg}"
      request.respond(500, emptyHttpHeaders(), fmt"Upload error: {e.msg}")
  
  else:
    # Show upload form
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html"
    
    let html = """
<!DOCTYPE html>
<html>
<head>
    <title>Basic File Upload</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .upload-form { border: 2px dashed #ccc; padding: 30px; text-align: center; }
        input[type="file"] { margin: 20px; }
        button { padding: 10px 20px; font-size: 16px; }
    </style>
</head>
<body>
    <h1>Basic File Upload Demo</h1>
    
    <div class="upload-form">
        <h3>Upload a File</h3>
        <form method="post" enctype="multipart/form-data">
            <input type="file" name="file" required>
            <br>
            <button type="submit">Upload File</button>
        </form>
    </div>
    
    <h2>Uploaded Files</h2>
    <div id="files">
        <p>Uploaded files will be saved to the 'uploads' directory.</p>
    </div>
</body>
</html>
"""
    
    request.respond(200, headers, html)

# Simple router setup
var router: Router
router.get("/", uploadHandler)
router.post("/", uploadHandler)

# Create basic server (no upload streaming for this simple example)
let server = newServer(router)

echo "Basic Upload Server"
echo "=================="
echo "Upload directory: uploads/"
echo "Serving on http://localhost:8080"

server.serve(Port(8080))