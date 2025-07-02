## TUS (resumable upload) protocol implementation for Mummy
## Implements the tus.io 1.0 specification for resumable file uploads

import std/[strutils, tables, base64, parseutils, strformat, times]
import uploads, ranges, common
import webby/httpheaders

export uploads, ranges

type
  TUSError* = object of CatchableError

  TUSVersion* = enum
    TUS_1_0 = "1.0.0"

  TUSExtension* = enum
    ## TUS protocol extensions
    TUSCreation,           ## File creation extension
    TUSTermination,        ## File termination extension  
    TUSChecksum,           ## Checksum extension
    TUSExpiration,         ## Expiration extension
    TUSConcatenation       ## Concatenation extension

  TUSConfig* = object
    ## Configuration for TUS protocol support
    version*: TUSVersion
    supportedExtensions*: set[TUSExtension]
    maxSize*: int64
    locationPrefix*: string    ## URL prefix for upload locations
    enableChecksum*: bool
    checksumAlgorithm*: string ## "sha1", "md5", etc.

  TUSHeaders* = object
    ## TUS-specific headers for requests and responses
    tusResumable*: string      ## Tus-Resumable header
    uploadLength*: int64       ## Upload-Length header (-1 if not present)
    uploadOffset*: int64       ## Upload-Offset header (-1 if not present)
    uploadMetadata*: Table[string, string]  ## Upload-Metadata parsed
    uploadChecksum*: string    ## Upload-Checksum header
    uploadConcat*: string      ## Upload-Concat header
    uploadExpires*: DateTime   ## Upload-Expires header

  TUSResponse* = object
    ## TUS protocol response
    statusCode*: int
    headers*: HttpHeaders
    body*: string

const
  TUS_VERSION_CURRENT* = TUS_1_0
  TUS_CHECKSUM_ALGORITHMS* = ["sha1", "md5", "sha256"]

proc defaultTUSConfig*(): TUSConfig =
  ## Default TUS configuration
  result = TUSConfig(
    version: TUS_1_0,
    supportedExtensions: {TUSCreation, TUSTermination, TUSChecksum},
    maxSize: 1024 * 1024 * 1024, # 1GB
    locationPrefix: "/files/",
    enableChecksum: true,
    checksumAlgorithm: "sha1"
  )

proc parseTUSHeaders*(headers: HttpHeaders): TUSHeaders =
  ## Parse TUS-specific headers from HTTP request
  result.uploadLength = -1
  result.uploadOffset = -1
  result.uploadMetadata = initTable[string, string]()
  
  for (key, value) in headers:
    let lowerKey = key.toLowerAscii()
    case lowerKey:
    of "tus-resumable":
      result.tusResumable = value
    of "upload-length":
      try:
        result.uploadLength = value.parseBiggestInt()
      except ValueError:
        discard
    of "upload-offset":
      try:
        result.uploadOffset = value.parseBiggestInt()
      except ValueError:
        discard
    of "upload-metadata":
      # Parse base64-encoded metadata pairs
      let pairs = value.split(",")
      for pair in pairs:
        let parts = pair.strip().split(" ", 1)
        if parts.len == 2:
          try:
            let decoded = base64.decode(parts[1])
            result.uploadMetadata[parts[0]] = decoded
          except:
            # Skip invalid metadata
            discard
    of "upload-checksum":
      result.uploadChecksum = value
    of "upload-concat":
      result.uploadConcat = value
    of "upload-expires":
      try:
        result.uploadExpires = value.parse("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
      except:
        discard

proc validateTUSRequest*(
  httpMethod: string,
  tusHeaders: TUSHeaders,
  config: TUSConfig
): tuple[valid: bool, error: string] =
  ## Validate TUS protocol request
  
  # Check TUS version
  if tusHeaders.tusResumable != $config.version:
    return (false, fmt"Unsupported TUS version: {tusHeaders.tusResumable}")
  
  case httpMethod.toUpperAscii():
  of "POST":
    # Creation request - should have Upload-Length
    if TUSCreation notin config.supportedExtensions:
      return (false, "Creation extension not supported")
    
    if tusHeaders.uploadLength < 0:
      return (false, "Upload-Length header required for POST")
    
    if config.maxSize > 0 and tusHeaders.uploadLength > config.maxSize:
      return (false, fmt"Upload length {tusHeaders.uploadLength} exceeds maximum {config.maxSize}")
  
  of "PATCH":
    # Upload chunk - should have Upload-Offset and Content-Type
    if tusHeaders.uploadOffset < 0:
      return (false, "Upload-Offset header required for PATCH")
  
  of "HEAD":
    # Status request - no specific requirements
    discard
  
  of "DELETE":
    # Termination request
    if TUSTermination notin config.supportedExtensions:
      return (false, "Termination extension not supported")
  
  else:
    return (false, fmt"Unsupported HTTP method for TUS: {httpMethod}")
  
  result = (true, "")

proc createTUSResponse*(
  statusCode: int,
  config: TUSConfig,
  uploadId: string = "",
  uploadOffset: int64 = -1,
  uploadLength: int64 = -1,
  additionalHeaders: HttpHeaders = emptyHttpHeaders()
): TUSResponse =
  ## Create TUS-compliant HTTP response
  result.statusCode = statusCode
  result.headers = additionalHeaders
  result.body = ""
  
  # Add standard TUS headers
  result.headers["Tus-Resumable"] = $config.version
  result.headers["Tus-Version"] = $config.version
  result.headers["Tus-Max-Size"] = $config.maxSize
  
  # Add supported extensions
  var extensions: seq[string]
  for ext in config.supportedExtensions:
    case ext:
    of TUSCreation: extensions.add("creation")
    of TUSTermination: extensions.add("termination")
    of TUSChecksum: extensions.add("checksum")
    of TUSExpiration: extensions.add("expiration")
    of TUSConcatenation: extensions.add("concatenation")
  
  if extensions.len > 0:
    result.headers["Tus-Extension"] = extensions.join(",")
  
  # Add checksum algorithms if supported
  if config.enableChecksum:
    result.headers["Tus-Checksum-Algorithm"] = config.checksumAlgorithm
  
  # Add upload-specific headers
  if uploadId.len > 0:
    result.headers["Location"] = config.locationPrefix & uploadId
  
  if uploadOffset >= 0:
    result.headers["Upload-Offset"] = $uploadOffset
  
  if uploadLength >= 0:
    result.headers["Upload-Length"] = $uploadLength
  
  # Add CORS headers for web compatibility
  result.headers["Access-Control-Allow-Origin"] = "*"
  result.headers["Access-Control-Allow-Methods"] = "POST, HEAD, PATCH, DELETE, OPTIONS"
  result.headers["Access-Control-Allow-Headers"] = "Content-Type, Upload-Length, Upload-Offset, Tus-Resumable, Upload-Metadata, Upload-Checksum"
  result.headers["Access-Control-Expose-Headers"] = "Upload-Offset, Location, Upload-Length, Tus-Version, Tus-Resumable, Tus-Max-Size, Tus-Extension, Upload-Metadata"

proc handleTUSCreation*(
  tusHeaders: TUSHeaders,
  manager: var UploadManager,
  clientId: uint64,
  config: TUSConfig
): TUSResponse =
  ## Handle TUS creation request (POST)
  try:
    # Extract filename from metadata
    let filename = tusHeaders.uploadMetadata.getOrDefault("filename", "upload.bin")
    
    # Create upload session
    let uploadId = manager.createUpload(filename, clientId, tusHeaders.uploadLength, "application/octet-stream")
    let upload = manager.getUpload(uploadId)
    
    if upload != nil:
      # Configure for TUS
      upload[].setRangeSupport(true)
      upload[].supportsRanges = true
      
      # Set checksum if provided
      if config.enableChecksum and tusHeaders.uploadChecksum.len > 0:
        upload[].setExpectedChecksum(tusHeaders.uploadChecksum)
      
      # Store TUS metadata
      for key, value in tusHeaders.uploadMetadata:
        upload[].metadata[key] = value
      
      result = createTUSResponse(201, config, uploadId, 0, tusHeaders.uploadLength)
    else:
      result = createTUSResponse(500, config)
      result.body = "Failed to create upload session"
  
  except UploadError as e:
    result = createTUSResponse(500, config)
    result.body = e.msg

proc handleTUSUpload*(
  tusHeaders: TUSHeaders,
  requestBody: string,
  uploadId: string,
  manager: var UploadManager,
  clientId: uint64,
  config: TUSConfig
): TUSResponse =
  ## Handle TUS upload chunk (PATCH)
  try:
    let upload = manager.getUpload(uploadId)
    if upload == nil:
      result = createTUSResponse(404, config)
      result.body = "Upload not found"
      return
    
    # Verify client ownership
    let clientUploads = manager.sessionsByClient.getOrDefault(clientId, @[])
    if uploadId notin clientUploads:
      result = createTUSResponse(403, config)
      result.body = "Upload not owned by client"
      return
    
    # Validate offset
    if tusHeaders.uploadOffset != upload[].bytesReceived:
      result = createTUSResponse(409, config)
      result.body = fmt"Offset mismatch: expected {upload[].bytesReceived}, got {tusHeaders.uploadOffset}"
      return
    
    # Ensure upload is open for writing
    if upload[].status == UploadPending:
      upload[].openForWriting()
    elif upload[].status != UploadInProgress:
      result = createTUSResponse(410, config)
      result.body = "Upload is no longer active"
      return
    
    # Write chunk data
    if requestBody.len > 0:
      upload[].writeChunk(requestBody.toOpenArrayByte(0, requestBody.len - 1))
    
    # Check if upload is complete
    if upload[].totalSize > 0 and upload[].bytesReceived >= upload[].totalSize:
      upload[].completeUpload()
    
    result = createTUSResponse(204, config, "", upload[].bytesReceived, upload[].totalSize)
    
  except UploadError as e:
    result = createTUSResponse(500, config)
    result.body = e.msg

proc handleTUSStatus*(
  uploadId: string,
  manager: var UploadManager,
  clientId: uint64,
  config: TUSConfig
): TUSResponse =
  ## Handle TUS status request (HEAD)
  try:
    let upload = manager.getUpload(uploadId)
    if upload == nil:
      result = createTUSResponse(404, config)
      return
    
    # Verify client ownership
    let clientUploads = manager.sessionsByClient.getOrDefault(clientId, @[])
    if uploadId notin clientUploads:
      result = createTUSResponse(403, config)
      return
    
    result = createTUSResponse(200, config, uploadId, upload[].bytesReceived, upload[].totalSize)
    result.headers["Cache-Control"] = "no-store"
    
    # Add metadata if present
    if upload[].metadata.len > 0:
      var metadataPairs: seq[string]
      for key, value in upload[].metadata:
        let encoded = base64.encode(value)
        metadataPairs.add(fmt"{key} {encoded}")
      result.headers["Upload-Metadata"] = metadataPairs.join(",")
    
  except Exception as e:
    result = createTUSResponse(500, config)
    result.body = e.msg

proc handleTUSTermination*(
  uploadId: string,
  manager: var UploadManager,
  clientId: uint64,
  config: TUSConfig
): TUSResponse =
  ## Handle TUS termination request (DELETE)
  try:
    if TUSTermination notin config.supportedExtensions:
      result = createTUSResponse(501, config)
      result.body = "Termination not supported"
      return
    
    let upload = manager.getUpload(uploadId)
    if upload == nil:
      result = createTUSResponse(404, config)
      return
    
    # Verify client ownership
    let clientUploads = manager.sessionsByClient.getOrDefault(clientId, @[])
    if uploadId notin clientUploads:
      result = createTUSResponse(403, config)
      return
    
    # Cancel the upload
    manager.removeUpload(uploadId)
    
    result = createTUSResponse(204, config)
    
  except Exception as e:
    result = createTUSResponse(500, config)
    result.body = e.msg

proc handleTUSOptions*(config: TUSConfig): TUSResponse =
  ## Handle TUS options request (OPTIONS)
  result = createTUSResponse(204, config)

proc extractUploadIdFromPath*(path: string, prefix: string): string =
  ## Extract upload ID from TUS request path
  if path.startsWith(prefix):
    result = path[prefix.len .. ^1]
    # Remove any trailing slashes or query parameters
    let slashPos = result.find('/')
    if slashPos >= 0:
      result = result[0 ..< slashPos]
    let queryPos = result.find('?')
    if queryPos >= 0:
      result = result[0 ..< queryPos]
  else:
    result = ""

proc isTUSRequest*(headers: HttpHeaders): bool =
  ## Check if request contains TUS headers
  for (key, value) in headers:
    if key.toLowerAscii() == "tus-resumable":
      return true
  result = false