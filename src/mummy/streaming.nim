## Streaming HTTP request body processing for large file uploads
## This module extends Mummy's existing HTTP parsing to support streaming request bodies to disk

import std/[tables, strutils, parseutils, nativesockets]
import uploads, common

type
  StreamingMode* = enum
    ## Defines how request body should be processed
    BufferInMemory,    ## Normal behavior - buffer in memory (existing)
    StreamToDisk,      ## Stream directly to disk for large uploads
    StreamToCallback   ## Stream to custom callback function

  StreamingCallback* = proc(data: openArray[byte], isComplete: bool): bool {.gcsafe.}
    ## Callback for streaming data processing
    ## Returns true to continue, false to abort

  StreamingContext* = object
    ## Context for streaming operations during HTTP parsing
    mode*: StreamingMode
    uploadSession*: ptr UploadSession  ## For StreamToDisk mode
    callback*: StreamingCallback       ## For StreamToCallback mode
    bufferSize*: int                   ## Size of streaming buffer
    totalBytesStreamed*: int64         ## Total bytes processed
    lastError*: string                 ## Last error message

  RequestBodyHandler* = object
    ## Enhanced request body handler that supports streaming
    isChunked*: bool
    contentLength*: int64
    bytesRemaining*: int64
    streamingContext*: StreamingContext
    buffer*: string                    ## Temporary buffer for chunk processing

proc initStreamingContext*(
  mode: StreamingMode = BufferInMemory,
  bufferSize: int = 64 * 1024
): StreamingContext =
  ## Initialize streaming context
  result = StreamingContext(
    mode: mode,
    bufferSize: bufferSize,
    totalBytesStreamed: 0
  )

proc shouldStreamToDisk*(
  headers: HttpHeaders,
  contentLength: int64,
  streamingThreshold: int64 = 10 * 1024 * 1024  # 10MB default
): bool =
  ## Determine if request should be streamed to disk based on size
  if contentLength > streamingThreshold:
    return true
  
  # Check for multipart uploads which might contain large files
  for (key, value) in headers:
    if key.toLowerAscii() == "content-type" and "multipart" in value.toLowerAscii():
      return true
  
  result = false

proc processStreamingChunk*(
  context: var StreamingContext,
  data: openArray[byte]
): bool =
  ## Process a chunk of streaming data
  try:
    case context.mode:
    of BufferInMemory:
      # This shouldn't happen in streaming mode, but handle gracefully
      return true
    
    of StreamToDisk:
      if context.uploadSession != nil:
        context.uploadSession[].writeChunk(data)
        context.totalBytesStreamed += data.len
        return true
      else:
        context.lastError = "No upload session for streaming to disk"
        return false
    
    of StreamToCallback:
      if context.callback != nil:
        let shouldContinue = context.callback(data, false)
        if shouldContinue:
          context.totalBytesStreamed += data.len
        return shouldContinue
      else:
        context.lastError = "No callback provided for streaming"
        return false
  
  except Exception as e:
    context.lastError = "Error processing chunk: " & e.msg
    return false

proc finishStreaming*(context: var StreamingContext): bool =
  ## Complete the streaming operation
  try:
    case context.mode:
    of BufferInMemory:
      return true
    
    of StreamToDisk:
      if context.uploadSession != nil:
        context.uploadSession[].completeUpload()
        return true
      else:
        context.lastError = "No upload session to complete"
        return false
    
    of StreamToCallback:
      if context.callback != nil:
        # Call callback with empty data and isComplete = true to signal completion
        return context.callback([], true)
      else:
        return true
  
  except Exception as e:
    context.lastError = "Error finishing stream: " & e.msg
    return false

proc initRequestBodyHandler*(
  isChunked: bool,
  contentLength: int64,
  streamingContext: StreamingContext
): RequestBodyHandler =
  ## Initialize request body handler
  result = RequestBodyHandler(
    isChunked: isChunked,
    contentLength: contentLength,
    bytesRemaining: if contentLength > 0: contentLength else: 0,
    streamingContext: streamingContext,
    buffer: newString(streamingContext.bufferSize)
  )

proc processChunkedStreamingData*(
  handler: var RequestBodyHandler,
  recvBuffer: string,
  startPos: int,
  availableBytes: int
): tuple[bytesProcessed: int, needMoreData: bool, isComplete: bool, shouldCloseConnection: bool] =
  ## Process chunked transfer encoding data with streaming support
  ## Returns (bytesProcessed, needMoreData, isComplete, shouldCloseConnection)
  
  var pos = startPos
  let endPos = startPos + availableBytes
  result = (bytesProcessed: 0, needMoreData: false, isComplete: false, shouldCloseConnection: false)
  
  while pos < endPos:
    # Look for chunk size line ending
    var chunkSizeEnd = -1
    for i in pos ..< min(endPos, pos + 20): # Reasonable limit for chunk size line
      if i + 1 < endPos and recvBuffer[i] == '\r' and recvBuffer[i + 1] == '\n':
        chunkSizeEnd = i
        break
    
    if chunkSizeEnd == -1:
      # Need more data to read chunk size
      result.needMoreData = true
      return
    
    # Parse chunk size
    let chunkSizeStr = recvBuffer[pos ..< chunkSizeEnd]
    var chunkSize: int
    try:
      chunkSize = parseHexInt(chunkSizeStr)
    except ValueError:
      result.shouldCloseConnection = true
      return
    
    if chunkSize < 0:
      result.shouldCloseConnection = true
      return
    
    # Move past chunk size and CRLF
    pos = chunkSizeEnd + 2
    
    # Check if we have the full chunk data + trailing CRLF
    if pos + chunkSize + 2 > endPos:
      result.needMoreData = true
      return
    
    # Process chunk data
    if chunkSize > 0:
      let chunkData = recvBuffer.toOpenArray(pos, pos + chunkSize - 1)
      if not handler.streamingContext.processStreamingChunk(chunkData):
        result.shouldCloseConnection = true
        return
    else:
      # Zero-length chunk indicates end of request
      if not handler.streamingContext.finishStreaming():
        result.shouldCloseConnection = true
        return
      result.isComplete = true
      pos += 2 # Skip trailing CRLF
      break
    
    # Move past chunk data and trailing CRLF
    pos += chunkSize + 2
  
  result.bytesProcessed = pos - startPos

proc processContentLengthStreamingData*(
  handler: var RequestBodyHandler,
  recvBuffer: string,
  startPos: int,
  availableBytes: int
): tuple[bytesProcessed: int, isComplete: bool, shouldCloseConnection: bool] =
  ## Process Content-Length data with streaming support
  
  let bytesToProcess = min(availableBytes, handler.bytesRemaining.int)
  if bytesToProcess <= 0:
    result = (bytesProcessed: 0, isComplete: true, shouldCloseConnection: false)
    return
  
  # Process the data chunk
  let chunkData = recvBuffer.toOpenArray(startPos, startPos + bytesToProcess - 1)
  if not handler.streamingContext.processStreamingChunk(chunkData):
    result = (bytesProcessed: 0, isComplete: false, shouldCloseConnection: true)
    return
  
  handler.bytesRemaining -= bytesToProcess
  
  if handler.bytesRemaining <= 0:
    # Complete the upload
    if not handler.streamingContext.finishStreaming():
      result = (bytesProcessed: bytesToProcess, isComplete: false, shouldCloseConnection: true)
      return
    result = (bytesProcessed: bytesToProcess, isComplete: true, shouldCloseConnection: false)
  else:
    result = (bytesProcessed: bytesToProcess, isComplete: false, shouldCloseConnection: false)

proc createStreamingRequestFromUpload*(
  uploadSession: ptr UploadSession,
  headers: HttpHeaders,
  httpMethod: string,
  uri: string,
  path: string,
  clientId: uint64,
  clientSocket: SocketHandle,
  serverPtr: pointer
): StreamingRequest =
  ## Create a StreamingRequest from an upload session
  result = StreamingRequest(
    httpVersion: Http11, # Assume HTTP/1.1 for uploads
    httpMethod: httpMethod,
    uri: uri,
    path: path,
    headers: headers,
    clientId: clientId,
    clientSocket: clientSocket,
    serverPtr: serverPtr
  )
  
  # Extract query params from URI if needed
  try:
    # This would need proper URL parsing - simplified for now
    let queryStart = uri.find('?')
    if queryStart >= 0:
      # Parse query parameters here
      discard
  except:
    discard

proc extractFilenameFromHeaders*(headers: HttpHeaders): string =
  ## Extract filename from Content-Disposition header
  for (key, value) in headers:
    if key.toLowerAscii() == "content-disposition":
      # Look for filename parameter
      let parts = value.split(';')
      for part in parts:
        let trimmed = part.strip()
        if trimmed.startsWith("filename="):
          var filename = trimmed[9 ..< trimmed.len]
          # Remove quotes if present
          if filename.len >= 2 and filename[0] == '"' and filename[^1] == '"':
            filename = filename[1 ..< filename.len - 1]
          return filename
  
  # Default filename if not found
  result = "upload_" & $now().toTime().toUnix()

proc setupStreamingUpload*(
  manager: var UploadManager,
  headers: HttpHeaders,
  clientId: uint64,
  httpMethod: string,
  uri: string,
  path: string,
  clientSocket: SocketHandle,
  serverPtr: pointer
): tuple[session: ptr UploadSession, request: StreamingRequest, success: bool, error: string] =
  ## Set up a streaming upload session
  try:
    let headerInfo = validateUploadHeaders(headers)
    if not headerInfo.valid:
      return (session: nil, request: StreamingRequest(), success: false, error: "Invalid headers")
    
    # Check disk space if content length is known
    if headerInfo.contentLength > 0:
      if not validateDiskSpace(manager.config, headerInfo.contentLength):
        return (session: nil, request: StreamingRequest(), success: false, error: "Insufficient disk space")
    
    # Extract filename
    let filename = extractFilenameFromHeaders(headers)
    
    # Create upload session
    let uploadId = manager.createUpload(filename, clientId, headerInfo.contentLength, headerInfo.contentType)
    let session = manager.getUpload(uploadId)
    if session == nil:
      return (session: nil, request: StreamingRequest(), success: false, error: "Failed to create upload session")
    
    # Open file for writing
    session[].openForWriting()
    
    # Create streaming request
    let request = createStreamingRequestFromUpload(
      session, headers, httpMethod, uri, path, clientId, clientSocket, serverPtr
    )
    
    result = (session: session, request: request, success: true, error: "")
    
  except Exception as e:
    result = (session: nil, request: StreamingRequest(), success: false, error: e.msg)