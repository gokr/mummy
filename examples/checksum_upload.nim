## Upload integrity verification with checksum example
## Demonstrates SHA1 checksum validation for upload data integrity

import ../src/mummy, ../src/mummy/routers, ../src/mummy/multipart
import std/[strformat, json, os, strutils, sha1, base64]

proc indexHandler(request: Request) =
  ## Serve checksum upload demo page
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html"
  
  let html = """
<!DOCTYPE html>
<html>
<head>
    <title>Checksum Upload Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .upload-area { border: 2px dashed #ccc; padding: 20px; margin: 20px 0; }
        .checksum-area { background: #f0f8ff; padding: 15px; margin: 10px 0; border-radius: 5px; }
        button { padding: 10px 20px; margin: 5px; }
        .status { margin: 10px 0; padding: 10px; background: #f9f9f9; }
        .success { background: #d4edda; color: #155724; }
        .error { background: #f8d7da; color: #721c24; }
        .info { background: #e8f5e8; padding: 10px; margin: 10px 0; }
        .log { background: #f8f8f8; padding: 10px; margin: 10px 0; font-family: monospace; font-size: 12px; max-height: 200px; overflow-y: auto; }
        input[type="text"] { width: 100%; padding: 8px; margin: 5px 0; }
        .hash-display { font-family: monospace; background: #f8f8f8; padding: 8px; border-radius: 3px; word-break: break-all; }
    </style>
</head>
<body>
    <h1>Checksum Upload Demo</h1>
    <p>This demo shows upload integrity verification using SHA1 checksums.</p>
    
    <div class="info">
        <strong>How it works:</strong>
        <ul>
            <li>Calculate SHA1 hash of file before upload</li>
            <li>Server calculates SHA1 hash during upload reception</li>
            <li>Server compares hashes to verify data integrity</li>
            <li>Upload fails if checksums don't match (data corruption detected)</li>
        </ul>
    </div>
    
    <div class="upload-area">
        <input type="file" id="fileInput" onchange="onFileSelected()">
        
        <div class="checksum-area">
            <label for="calculatedHash"><strong>Calculated SHA1 Hash:</strong></label>
            <div id="calculatedHash" class="hash-display">Select a file to calculate hash...</div>
            <br>
            
            <label for="expectedHash"><strong>Expected Hash (optional):</strong></label>
            <input type="text" id="expectedHash" placeholder="Enter expected SHA1 hash to verify against">
            <small>Leave empty to just verify integrity during upload</small>
        </div>
        
        <button onclick="startUpload()" id="uploadBtn" disabled>Upload with Checksum Verification</button>
        <button onclick="simulateCorruption()" id="corruptBtn" disabled>Test Corruption Detection</button>
        
        <div id="status" class="status">Select a file to begin</div>
    </div>
    
    <div class="log" id="log"></div>

    <script>
        let selectedFile = null;
        let calculatedHash = null;
        
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
        
        async function calculateSHA1(file) {
            return new Promise((resolve, reject) => {
                const reader = new FileReader();
                reader.onload = async function(e) {
                    try {
                        const arrayBuffer = e.target.result;
                        const hashBuffer = await crypto.subtle.digest('SHA-1', arrayBuffer);
                        const hashArray = Array.from(new Uint8Array(hashBuffer));
                        const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
                        resolve(hashHex);
                    } catch (error) {
                        reject(error);
                    }
                };
                reader.onerror = reject;
                reader.readAsArrayBuffer(file);
            });
        }
        
        async function onFileSelected() {
            const fileInput = document.getElementById('fileInput');
            selectedFile = fileInput.files[0];
            
            if (!selectedFile) {
                document.getElementById('calculatedHash').textContent = 'Select a file to calculate hash...';
                document.getElementById('uploadBtn').disabled = true;
                document.getElementById('corruptBtn').disabled = true;
                return;
            }
            
            document.getElementById('status').textContent = 'Calculating SHA1 hash...';
            document.getElementById('calculatedHash').textContent = 'Calculating...';
            
            try {
                calculatedHash = await calculateSHA1(selectedFile);
                document.getElementById('calculatedHash').textContent = calculatedHash;
                document.getElementById('status').textContent = `File: ${selectedFile.name} (${formatBytes(selectedFile.size)}) - Hash calculated`;
                document.getElementById('uploadBtn').disabled = false;
                document.getElementById('corruptBtn').disabled = false;
                
                log(`File selected: ${selectedFile.name}`);
                log(`SHA1 calculated: ${calculatedHash}`);
            } catch (error) {
                document.getElementById('calculatedHash').textContent = 'Error calculating hash: ' + error.message;
                document.getElementById('status').textContent = 'Hash calculation failed';
                log(`Hash calculation error: ${error.message}`);
            }
        }
        
        async function uploadFile(useCorruptData = false) {
            if (!selectedFile || !calculatedHash) {
                alert('Please select a file first');
                return;
            }
            
            document.getElementById('uploadBtn').disabled = true;
            document.getElementById('corruptBtn').disabled = true;
            
            const expectedHash = document.getElementById('expectedHash').value.trim();
            
            // Check if expected hash matches calculated hash
            if (expectedHash && expectedHash.toLowerCase() !== calculatedHash.toLowerCase()) {
                document.getElementById('status').className = 'status error';
                document.getElementById('status').textContent = 'Expected hash does not match calculated hash!';
                log('Hash mismatch detected before upload');
                document.getElementById('uploadBtn').disabled = false;
                document.getElementById('corruptBtn').disabled = false;
                return;
            }
            
            try {
                let fileData;
                if (useCorruptData) {
                    // Simulate corruption by modifying the file data
                    const originalArray = new Uint8Array(await selectedFile.arrayBuffer());
                    if (originalArray.length > 100) {
                        originalArray[50] = originalArray[50] ^ 0xFF; // Flip some bits
                        originalArray[100] = originalArray[100] ^ 0xFF;
                    }
                    fileData = new Blob([originalArray], { type: selectedFile.type });
                    log('Simulating data corruption for testing...');
                } else {
                    fileData = selectedFile;
                }
                
                const formData = new FormData();
                formData.append('file', fileData, selectedFile.name);
                formData.append('expectedChecksum', calculatedHash);
                
                document.getElementById('status').textContent = 'Uploading with checksum verification...';
                log(`Starting upload with checksum: ${calculatedHash}`);
                
                const response = await fetch('/checksum/upload', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                
                if (result.success) {
                    document.getElementById('status').className = 'status success';
                    document.getElementById('status').textContent = 
                        `Upload successful! Server verified checksum: ${result.calculatedChecksum}`;
                    log(`Upload completed successfully`);
                    log(`Server calculated checksum: ${result.calculatedChecksum}`);
                    log(`Checksums match: ${result.calculatedChecksum.toLowerCase() === calculatedHash.toLowerCase()}`);
                } else {
                    document.getElementById('status').className = 'status error';
                    document.getElementById('status').textContent = `Upload failed: ${result.error}`;
                    log(`Upload failed: ${result.error}`);
                }
            } catch (error) {
                document.getElementById('status').className = 'status error';
                document.getElementById('status').textContent = `Upload error: ${error.message}`;
                log(`Upload error: ${error.message}`);
            }
            
            document.getElementById('uploadBtn').disabled = false;
            document.getElementById('corruptBtn').disabled = false;
        }
        
        function startUpload() {
            uploadFile(false);
        }
        
        function simulateCorruption() {
            if (confirm('This will simulate data corruption to test checksum validation. Continue?')) {
                uploadFile(true);
            }
        }
        
        // Initial state
        log('Checksum upload client ready');
        log('Using SHA1 for integrity verification');
        log('Select a file to calculate its hash');
    </script>
</body>
</html>
"""
  
  request.respond(200, headers, html)

proc checksumUploadHandler(request: Request) =
  ## Handle upload with checksum verification
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  
  try:
    # Parse multipart form data
    let multipart = request.decodeMultipart()
    var fileData = ""
    var expectedChecksum = ""
    var filename = "upload.bin"
    
    # Extract file data and checksum from multipart
    for entry in multipart:
      case entry.name:
      of "file":
        if entry.filename.isSome and entry.data.isSome:
          filename = entry.filename.get()
          let (start, last) = entry.data.get()
          fileData = request.body[start .. last]
      of "expectedChecksum":
        if entry.data.isSome:
          let (start, last) = entry.data.get()
          expectedChecksum = request.body[start .. last]
    
    if fileData.len == 0:
      let response = %*{
        "success": false,
        "error": "No file data found"
      }
      request.respond(400, headers, $response)
      return
    
    # Calculate actual checksum
    let calculatedChecksum = $secureHash(fileData)
    
    # Create upload with checksum verification
    let uploadId = request.createUpload(filename, fileData.len)
    let upload = request.getUpload(uploadId)
    
    if upload != nil:
      if expectedChecksum.len > 0:
        upload[].setExpectedChecksum(expectedChecksum)
      
      # Write and complete upload
      upload[].openForWriting()
      upload[].writeChunk(fileData.toOpenArrayByte(0, fileData.len - 1))
      upload[].completeUpload()
      
      let response = %*{
        "success": true,
        "calculatedChecksum": calculatedChecksum,
        "expectedChecksum": expectedChecksum,
        "filename": filename,
        "size": fileData.len,
        "uploadPath": upload[].finalPath
      }
      request.respond(200, headers, $response)
    else:
      let response = %*{
        "success": false,
        "error": "Failed to create upload session"
      }
      request.respond(500, headers, $response)
      
  except UploadError as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(400, headers, $response)
  except Exception as e:
    let response = %*{
      "success": false,
      "error": e.msg
    }
    request.respond(500, headers, $response)

# Router setup
var router: Router
router.get("/", indexHandler)
router.post("/checksum/upload", checksumUploadHandler)

# Configure upload settings
var uploadConfig = defaultUploadConfig()
uploadConfig.uploadDir = "uploads"
uploadConfig.tempDir = "uploads/tmp"
uploadConfig.maxFileSize = 100 * 1024 * 1024  # 100MB
uploadConfig.enableIntegrityCheck = true

# Create server with checksum verification
let server = newServer(
  router,
  enableUploads = true,
  uploadConfig = uploadConfig,
  maxBodyLen = 100 * 1024 * 1024  # 100MB max
)

echo "Checksum Upload Server"
echo "====================="
echo "Algorithm: SHA1"
echo "Features: integrity verification, corruption detection"
echo "Upload directory: uploads/"
echo "Max file size: 100MB"
echo "Serving on http://localhost:8080"

server.serve(Port(8080))