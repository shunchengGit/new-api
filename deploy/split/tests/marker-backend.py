#!/usr/bin/env python3
import http.server
import json
import socketserver
import sys
import time

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, fmt, *args): pass
    def _reply(self, body, content_type='application/json', headers=()):
        data = body.encode()
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        for key, value in headers: self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path in ('/v1/sse', '/api/sse'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            self.wfile.write(b'data: immediate\n\n')
            self.wfile.flush()
            time.sleep(2)
            self.wfile.write(b'data: complete\n\n')
            self.wfile.flush()
            return
        if self.path == '/v1/realtime' and self.headers.get('Upgrade', '').lower() == 'websocket':
            self.send_response(101, 'Switching Protocols')
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            if self.headers.get('Sec-WebSocket-Protocol'):
                self.send_header('Sec-WebSocket-Protocol', self.headers['Sec-WebSocket-Protocol'].split(',')[0].strip())
            self.end_headers()
            return
        self._reply(json.dumps({'path': self.path, 'query': self.path.partition('?')[2], 'xff': self.headers.get('X-Forwarded-For'), 'host': self.headers.get('Host')}))
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        body = self.rfile.read(length).decode()
        self._reply(json.dumps({'path': self.path, 'query': self.path.partition('?')[2], 'body': body if length < 4096 else '', 'body_size': length, 'signature': self.headers.get('X-Signature')}))

socketserver.ThreadingTCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(('0.0.0.0', int(sys.argv[1])), Handler) as server:
    server.serve_forever()
