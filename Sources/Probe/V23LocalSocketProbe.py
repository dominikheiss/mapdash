#!/usr/bin/env python3
"""V23: loopback-only WebSocket probe for the game-owned session socket.

Numeric session IDs arrive on stdin, are used only in localhost paths, and are
never stored or logged. Raw socket frames are not logged. Read-only protocol
observation; no Blizzard authentication, game-process writes or map downloads.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import socket
import struct
import sys
import time

MAGIC = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HEADER = 16384
MAX_PAYLOAD = 2 * 1024 * 1024
MAX_MESSAGES = 50
SAFE = re.compile(r"[^\x20-\x7e]")
HASH = re.compile(r"^[0-9a-fA-F]{40}$")

def sanitize(value, cap=110):
    return SAFE.sub("?", str(value))[:cap].replace('"', "'").replace('\\', '/')

def dict_str(d, keys):
    if not isinstance(d, dict):
        return ""
    for k in keys:
        if isinstance(d.get(k), str):
            return d[k]
    return ""

def keys(d):
    if not isinstance(d, dict):
        return "none"
    return ",".join(sorted(sanitize(k, 30) for k in d.keys())[:30])[:600]

def games_in(value, depth=0):
    if depth > 6:
        return []
    if isinstance(value, list):
        out=[]
        for item in value[:500]:
            out += games_in(item, depth+1)
        return out
    if not isinstance(value, dict):
        return []
    title = dict_str(value, ("name", "gameName", "lobbyName", "title"))
    result=[]
    if title:
        result.append(value)
    for k, v in value.items():
        if isinstance(v, (dict, list)):
            result += games_in(v, depth+1)
    return result

def describe_message(raw, query):
    try:
        value=json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        print("v23_message=json_unrecognized")
        return 0
    if not isinstance(value, dict):
        print("v23_message=root_not_object")
        return 0
    mtype=dict_str(value,("messageType", "type", "event")) or "unknown"
    payload=value.get("payload")
    print("v23_message type=%s root_keys=%s payload_keys=%s" %
          (sanitize(mtype,60), keys(value), keys(payload)))
    found=0
    for game in games_in(payload if payload is not None else value):
        title=dict_str(game,("name", "gameName", "lobbyName", "title"))
        mp=dict_str(game,("mapName", "map", "mapFile", "mapPath", "map_name"))
        if query and query.lower() not in title.lower() and query.lower() not in mp.lower():
            continue
        hash_fields=[]
        for field, v in game.items():
            if any(t in field.lower() for t in ("hash", "sha", "checksum")):
                kind = "hex40" if isinstance(v,str) and HASH.fullmatch(v) else type(v).__name__
                hash_fields.append("%s:%s" % (sanitize(field,35),kind))
        print('v23_game title="%s" map="%s" host="%s" hash_field_shapes=%s' %
              (sanitize(title),sanitize(mp),sanitize(dict_str(game,("host","hostName","creator"))),
               sanitize(",".join(hash_fields),200) or "none"))
        found += 1
        if found >= 10:
            break
    return found

class ProtocolFailure(Exception):
    pass

class FrameSocket:
    def __init__(self,sock, initial=b""):
        self.sock=sock
        self.buf=initial

    def read(self,n,deadline):
        while len(self.buf)<n:
            remaining=deadline-time.monotonic()
            if remaining <= 0:
                raise TimeoutError("deadline")
            self.sock.settimeout(min(remaining,1.0))
            try:
                more=self.sock.recv(min(65536,max(4096,n-len(self.buf))))
            except socket.timeout:
                continue
            if not more:
                raise ProtocolFailure("connection_closed")
            self.buf+=more
        data,self.buf=self.buf[:n],self.buf[n:]
        return data

    def recv_frame(self,deadline):
        h=self.read(2,deadline)
        opcode=h[0]&0x0f
        masked=bool(h[1]&0x80)
        length=h[1]&0x7f
        if length==126:
            length=struct.unpack("!H",self.read(2,deadline))[0]
        elif length==127:
            length=struct.unpack("!Q",self.read(8,deadline))[0]
        if length>MAX_PAYLOAD:
            raise ProtocolFailure("frame_too_large")
        mask=self.read(4,deadline) if masked else b""
        data=self.read(length,deadline)
        if masked:
            data=bytes(b^mask[i%4] for i,b in enumerate(data))
        return opcode, bool(h[0]&0x80), data

    def send_control(self,opcode,data=b""):
        if len(data)>125:
            return
        mask=secrets.token_bytes(4)
        payload=bytes(b^mask[i%4] for i,b in enumerate(data))
        self.sock.sendall(bytes((0x80|opcode,0x80|len(data)))+mask+payload)

def handshake(port,ident):
    sock=socket.create_connection(("127.0.0.1",port),timeout=2.0)
    try:
        nonce=base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        req=("GET /webui-socket/%s HTTP/1.1\r\n" % ident +
             "Host: 127.0.0.1:%d\r\n" % port +
             "Upgrade: websocket\r\nConnection: Upgrade\r\n"+
             "Sec-WebSocket-Key: %s\r\n" % nonce +
             "Sec-WebSocket-Version: 13\r\n\r\n")
        sock.sendall(req.encode("ascii"))
        buf=b""
        sock.settimeout(2.0)
        while b"\r\n\r\n" not in buf:
            piece=sock.recv(4096)
            if not piece:
                raise ProtocolFailure("closed_during_handshake")
            buf+=piece
            if len(buf)>MAX_HEADER:
                raise ProtocolFailure("header_too_large")
        head,extra=buf.split(b"\r\n\r\n",1)
        lines=head.decode("latin1").split("\r\n")
        match=re.match(r"^HTTP/1\.[01] (\d{3})",lines[0])
        if not match:
            raise ProtocolFailure("not_http_response")
        status=int(match.group(1))
        if status!=101:
            raise ProtocolFailure("http_%s" % status)
        response_headers={}
        for line in lines[1:]:
            if ":" in line:
                k,v=line.split(":",1)
                response_headers[k.strip().lower()]=v.strip()
        expected=base64.b64encode(hashlib.sha1(nonce.encode("ascii")+MAGIC).digest()).decode("ascii")
        if response_headers.get("sec-websocket-accept")!=expected:
            raise ProtocolFailure("incorrect_websocket_accept")
        if "websocket" not in response_headers.get("upgrade","").lower():
            raise ProtocolFailure("missing_upgrade_header")
        return FrameSocket(sock,extra)
    except Exception:
        sock.close()
        raise

def probe(ids,ports,query,seconds):
    # Actual IDs never enter logs or command line arguments.
    ids=list(dict.fromkeys(x for x in ids if re.fullmatch(r"[0-9]{11,32}",x)))[:16]
    print("v23_session_ids=%d (values redacted)" % len(ids))
    print("v23_loopback_ports=%s" % (",".join(str(x) for x in ports) or "none"))
    if not ids:
        print("v23_status=NO_SESSION_ID_FROM_MEMORY")
        return 1
    if not ports:
        print("v23_status=NO_GAME_OWNED_LISTENER")
        return 1
    for port in ports:
        for ident in ids:
            try:
                stream=handshake(port,ident)
            except (OSError, ProtocolFailure,TimeoutError) as e:
                reason=(str(e) if isinstance(e,ProtocolFailure) else type(e).__name__)
                print("v23_handshake port=%d outcome=%s" % (port,sanitize(reason,48)))
                continue
            print("v23_websocket port=%d outcome=CONNECTED (no raw frames logged)" % port)
            hits=0
            message_count=0
            deadline=time.monotonic()+seconds
            fragments=bytearray()
            try:
                while time.monotonic()<deadline and message_count<MAX_MESSAGES:
                    try:
                        op,fin,data=stream.recv_frame(deadline)
                    except TimeoutError:
                        break
                    if op==0x9:
                        stream.send_control(0xA,data)
                        continue
                    if op==0x8:
                        break
                    if op in (0x1,0x2):
                        fragments=bytearray()
                    elif op!=0x0:
                        continue
                    if len(fragments)+len(data)>MAX_PAYLOAD:
                        raise ProtocolFailure("message_too_large")
                    fragments.extend(data)
                    if fin:
                        message_count+=1
                        if op!=0x2:
                            hits+=describe_message(bytes(fragments),query)
                        fragments=bytearray()
            except (ProtocolFailure,OSError,UnicodeError) as e:
                print("v23_stream_end=%s" % sanitize(str(e),40))
            finally:
                try:
                    stream.send_control(0x8)
                except (OSError,TimeoutError):
                    pass
                stream.sock.close()
            print("v23_summary messages=%d matching_games=%d" % (message_count,hits))
            print("v23_status=LOCAL_WEBSOCKET_CONFIRMED" if message_count else "v23_status=WEBSOCKET_CONNECTED_NO_MESSAGES")
            return 0
    print("v23_status=NO_VERIFIED_WEBSOCKET_ON_LISTENERS")
    return 1

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--ports",required=True,help="Comma-separated local game-owned ports")
    ap.add_argument("--query",default="Footmen")
    ap.add_argument("--seconds",type=int,default=12)
    args=ap.parse_args()
    ports=[]
    for text in args.ports.split(","):
        if text.isdecimal() and 0<int(text)<65536:
            ports.append(int(text))
    ports=list(dict.fromkeys(ports))[:8]
    # No IDs appear in arguments, environment variables, logs, or files.
    ids=sys.stdin.read().splitlines()
    return probe(ids,ports,args.query,max(1,min(30,args.seconds)))

if __name__ == "__main__":
    raise SystemExit(main())
