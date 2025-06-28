# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Building and Testing
```bash
# Install dependencies
nimble install -y

# Run main test suite
nim c -r -d:useMalloc tests/test.nim

# Run HTTP tests
nim c -r -d:useMalloc tests/test_http.nim

# Run HTTP/2 tests
nim c -r -d:useMalloc tests/test_http2.nim

# Run WebSocket tests
nim c -r -d:useMalloc tests/test_websockets.nim

# Run multipart tests
nim c -r -d:useMalloc tests/test_multipart.nim

# Run router tests
nim c -r -d:useMalloc tests/test_routers.nim

# Run fuzzer (for security testing)
nim c -r -d:useMalloc -d:mummyNoWorkers tests/fuzz_recv.nim
```

### Running Examples
```bash
# Basic HTTP server example
nim c --threads:on --mm:orc -r examples/basic_router.nim

# WebSocket server example
nim c --threads:on --mm:orc -r examples/basic_websockets.nim

# Other examples (all require --threads:on --mm:orc)
nim c --threads:on --mm:orc -r examples/basic.nim
nim c --threads:on --mm:orc -r examples/chat.nim
```

### Compilation Requirements
All Mummy code must be compiled with:
- `--threads:on` (required for multithreading)
- `--mm:orc` or `--mm:arc` (required memory management)

## Project Architecture

### Core Design Philosophy
Mummy is a multithreaded HTTP/WebSocket server that handles socket I/O on one thread and dispatches requests to worker threads. This avoids async/await complexity while maintaining high performance.

### Key Components

#### Main Server (`src/mummy.nim`)
- `Server` type: Core server implementation with worker thread pool
- `Request` type: HTTP request representation with respond methods
- `WebSocket` type: WebSocket connection handling
- Thread-safe queuing system for requests and responses

#### Internal Implementation (`src/mummy/internal.nim`)
- Frame encoding/decoding for WebSocket protocol
- HTTP header parsing and encoding utilities
- Low-level socket operations and buffer management

#### Router System (`src/mummy/routers.nim`)
- Pattern-based URL routing with wildcards (`*`, `**`)
- HTTP method matching
- Path parameter extraction
- Middleware-style error handling

#### Supporting Modules
- `common.nim`: Shared types and utilities
- `multipart.nim`: Multipart form data parsing
- `fileloggers.nim`: File-based logging implementations

### Request/Response Flow
1. Socket I/O thread receives HTTP requests
2. Parsed requests queued for worker threads
3. Worker threads execute user handlers
4. Responses queued back to I/O thread
5. I/O thread sends responses to clients

### WebSocket Architecture
- Upgrade from HTTP handled seamlessly
- Frame parsing/encoding in I/O thread
- Message events dispatched to worker threads
- Serial event processing per connection

### Threading Model
- Single I/O thread handles all socket operations
- Configurable worker thread pool (default: 10 * CPU cores)
- Lock-free queues for cross-thread communication
- Automatic request/response correlation

## Development Notes

### Testing Strategy
- Unit tests for core functionality
- HTTP protocol compliance tests
- WebSocket protocol tests
- Fuzzing for security validation
- Memory usage testing with `-d:useMalloc`

### Performance Considerations
- Optimized for API servers, not large file serving
- Memory-efficient request/response handling
- Zero-copy operations where possible
- Automatic gzip/deflate compression

### Dependencies
- `webby`: URL parsing and HTTP utilities
- `zippy`: Compression support
- `crunchy`: Cryptographic functions for WebSocket handshake