"""
MacMic Protocol Implementation for macOS.
Compatible with the WO Mic mobile app protocol.
Handles TCP control commands (handshake, codec params, audio capture) and UDP/TCP media streaming.
"""

import socket
import struct
import threading
import time
from typing import Callable, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from macmic_audio import AudioOutputEngine


RECOVERY_HINT = (
    "On the phone, keep WO Mic in the foreground and the screen awake. "
    "If it shows Connected (已连接), tap Stop → Start (停止→开始) until "
    "Waiting for connection (等待连接) appears; disconnect other clients. "
    "Check the current phone IP/Wi-Fi signal, or use USB (ADB)."
)


# Protocol constants for interoperability with the WO Mic phone app
# (control/media protocol used by the WO Mic Android app).
PROTOCOL_VERSION_V4 = 4
CLIENT_MAJOR = 6
CLIENT_MINOR = 3
CLIENT_PATCH = 0

CMD_CHECK_VERSION = 0x65       # 101: Handshake and version check
CMD_SET_CODEC_PARAM = 0x66     # 102: Configure audio codec & client UDP port
CMD_START_CAPTURE = 0x67       # 103: Request server to start streaming audio
CMD_STOP_CAPTURE = 0x68        # 104: Stop audio capture / disconnect
CMD_HEARTBEAT = 0x69           # 105: Keepalive heartbeat poll (resets 5s timeout on server)

CODEC_OPUS = 0x02              # Opus audio codec ID
SAMPLE_RATE_INDEX_48K = 0x02   # Sample rate index: 0=8kHz, 1=16kHz, 2=48kHz
PROTOCOL_VERSION_V4_BE = 0x0400  # Protocol version 4 in big-endian 2-byte form (for UDP header)

# UDP Media Packet Header: 11 bytes total
# [proto_ver (2 BE)] [data_len (2 BE)] [seq (2 BE)] [timestamp (4 BE)] [flag (1)]
# data_len = opus_payload_size + 7 (seq + ts + flag fields)
UDP_MEDIA_HEADER_SIZE = 11

DEFAULT_CONTROL_PORT = 8125
DEFAULT_MEDIA_PORT = 8125


class ConnectionState:
    DISCONNECTED = "Disconnected"
    CONNECTING = "Connecting"
    CONNECTED = "Connected"
    STREAMING = "Streaming (Mic Active)"
    ERROR = "Error"


class MacMicClient:
    """
    MacMic Client implementation for macOS.
    """

    def __init__(
        self,
        host: str = "127.0.0.1",
        control_port: int = DEFAULT_CONTROL_PORT,
        media_port: int = DEFAULT_MEDIA_PORT,
        is_tcp_media: bool = False,
        audio_engine: Optional["AudioOutputEngine"] = None,
        on_state_change: Optional[Callable[[str, str], None]] = None,
    ):
        self.host = host
        self.control_port = control_port
        self.media_port = media_port
        self.is_tcp_media = is_tcp_media  # True for USB (ADB), False for Wi-Fi (UDP)
        
        # Load audio/Opus only for streaming, so diagnosis needs no audio device.
        self.audio_engine = audio_engine
        self.decoder = None
        
        self.state = ConnectionState.DISCONNECTED
        self.on_state_change = on_state_change
        
        self._control_sock = None
        self._media_sock = None
        self._is_running = False
        
        self._worker_thread = None
        self._poll_thread = None
        self._last_seq = -1
        self._packets_received = 0
        self._bytes_received = 0
        self._last_packet_time = 0.0
        self.last_error = ""
        self._lifecycle_lock = threading.RLock()
        self._decode_lock = threading.Lock()
        self._send_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._cancel_connect = threading.Event()
        self._stage = ""

    def _set_state(self, state: str, detail: str = ""):
        self.state = state
        if self.on_state_change:
            try:
                self.on_state_change(state, detail)
            except Exception:
                pass

    def connect(self, timeout: float = 5.0, attempts: int = 3,
                handshake_only: bool = False) -> bool:
        """Bounded attempts (1/2s backoff); timeout is the WHOLE attempt budget.

        handshake_only probes 0x65 on the same TCP connection, without capture
        or audio dependencies. The caller must still disconnect in a finally.
        """
        if not 0 < timeout <= 30 or not 1 <= attempts <= 3:
            raise ValueError("timeout must be >0 and <=30s; attempts must be 1..3")
        with self._lifecycle_lock:
            self._cleanup()
            self._cancel_connect.clear()
            self.last_error = ""
            self._packets_received = self._bytes_received = 0
            self._last_seq = -1
            self._last_packet_time = time.time()
            for attempt in range(1, attempts + 1):
                if self._cancel_connect.is_set():
                    return False
                self._stop_event = threading.Event()
                self._is_running = True
                self._set_state(ConnectionState.CONNECTING,
                                f"Connecting to {self.host}:{self.control_port} ({attempt}/{attempts})")
                deadline = time.monotonic() + timeout
                try:
                    if not handshake_only:
                        self._stage = "Initialize audio/Opus"
                        from macmic_opus import OpusDecoder
                        self.decoder = OpusDecoder(sample_rate=48000, channels=1)
                        if self.audio_engine is None:
                            from macmic_audio import AudioOutputEngine
                            self.audio_engine = AudioOutputEngine()
                    # Bind BEFORE 0x66 advertises the local port. Never silently
                    # fall back to an unadvertised port or share another client's UDP socket.
                    if not handshake_only and not self.is_tcp_media:
                        self._stage = f"Bind local UDP port {self.media_port}"
                        self._media_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                        self._media_sock.bind(("0.0.0.0", self.media_port))
                        self._media_sock.settimeout(0.5)
                    self._stage = "TCP connect"
                    self._control_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    self._control_sock.settimeout(self._remaining(deadline))
                    self._control_sock.connect((self.host, self.control_port))
                    self._exchange(CMD_CHECK_VERSION,
                                   bytes([PROTOCOL_VERSION_V4, CLIENT_MAJOR, CLIENT_MINOR, 0, 0, 0]),
                                   deadline)
                    if handshake_only:
                        self._set_state(ConnectionState.CONNECTED, "TCP and handshake 0x65 succeeded")
                        return True
                    local_port = (self.media_port if self.is_tcp_media
                                  else self._media_sock.getsockname()[1])
                    self._exchange(CMD_SET_CODEC_PARAM,
                                   bytes([CODEC_OPUS, SAMPLE_RATE_INDEX_48K]) + struct.pack(">I", local_port),
                                   deadline)
                    self._exchange(CMD_START_CAPTURE, b"", deadline)
                    if self.is_tcp_media:
                        self._stage = "TCP media connect"
                        self._media_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                        self._media_sock.settimeout(self._remaining(deadline))
                        self._media_sock.connect((self.host, self.media_port))
                        self._media_sock.settimeout(0.5)
                    self._remaining(deadline)
                    self._stage = "Start audio output"
                    if not self.audio_engine.is_running:
                        self.audio_engine.start(getattr(self.audio_engine, "device_index", None))
                    self._remaining(deadline)
                    self._control_sock.settimeout(0.5)
                    stop = self._stop_event
                    target = self._media_tcp_loop if self.is_tcp_media else self._media_udp_loop
                    self._worker_thread = threading.Thread(
                        target=target, args=(self._media_sock, stop), name="MacMic-media", daemon=True)
                    self._poll_thread = threading.Thread(
                        target=self._poll_loop, args=(stop,), name="MacMic-heartbeat", daemon=True)
                    self._worker_thread.start()
                    self._poll_thread.start()
                    self._set_state(ConnectionState.STREAMING, f"Mic active ({self.host})")
                    return True
                except Exception as exc:
                    if isinstance(exc, socket.timeout):
                        kind = "timeout" if "connect" in self._stage else "read/handshake timeout"
                        detail = f"{self._stage}: {kind} (attempt budget {timeout:g}s)."
                    else:
                        detail = f"{self._stage}: {exc}."
                    self.last_error = f"{detail} {RECOVERY_HINT}"
                    # Stop + abortive close completes BEFORE waiting/retrying.
                    self._cleanup()
                    if self._cancel_connect.is_set():
                        self._set_state(ConnectionState.DISCONNECTED, "Connection cancelled")
                        return False
                    if attempt < attempts:
                        self._set_state(ConnectionState.CONNECTING,
                                        f"{self.last_error} Retrying in {attempt}s ({attempt}/{attempts}).")
                        if self._cancel_connect.wait(attempt):
                            return False
            self._set_state(ConnectionState.ERROR, self.last_error)
            return False

    def _remaining(self, deadline):
        if self._cancel_connect.is_set():
            raise ConnectionAbortedError("Connection cancelled")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise socket.timeout("Attempt deadline expired")
        return remaining

    def _exchange(self, command, payload, deadline):
        self._stage = f"Handshake 0x{command:02x}"
        self._control_sock.settimeout(self._remaining(deadline))
        self._send_control_cmd(command, payload)
        kind, status, _ = self._read_control_response(deadline)
        if kind != command or status != 0:
            raise ConnectionError(f"Unexpected response type=0x{kind:02x}, status={status}")

    def _send_control_cmd(self, cmd_type: int, payload: bytes):
        """Sends a structured control command frame."""
        # Header: [cmd_type (1 byte)] [payload_len (4 bytes BE)]
        header = struct.pack(">BI", cmd_type, len(payload))
        with self._send_lock:
            if self._control_sock is None:
                raise ConnectionError("Control socket is closed")
            self._control_sock.sendall(header + payload)

    def _read_exact(self, sock: socket.socket, length: int, deadline=None, stop=None) -> bytes:
        """Read a frame with a total deadline, not a fresh timeout per byte."""
        buf = bytearray()
        while len(buf) < length:
            if stop is not None and stop.is_set():
                raise ConnectionAbortedError("Stream stopped")
            if deadline is not None:
                sock.settimeout(self._remaining(deadline))
            try:
                chunk = sock.recv(length - len(buf))
            except socket.timeout:
                if stop is not None:
                    continue
                raise
            if not chunk:
                raise ConnectionError("Received 0 bytes (EOF): peer closed the connection; "
                                      "WO Mic may already show Connected (已连接). " + RECOVERY_HINT)
            buf.extend(chunk)
        return bytes(buf)

    def _read_control_response(self, deadline=None) -> tuple[int, int, bytes]:
        """Reads a structured control response frame: (type, status, data)."""
        # Response header: [type (1 byte)] [length (4 bytes BE)]
        raw_header = self._read_exact(self._control_sock, 5, deadline)
        resp_type, length = struct.unpack(">BI", raw_header)
        if length > 65536:
            raise ConnectionError(f"Invalid control response length: {length}")
        if length > 0:
            status_byte = self._read_exact(self._control_sock, 1, deadline)[0]
            payload = self._read_exact(self._control_sock, length - 1, deadline) if length > 1 else b""
        else:
            status_byte = 0
            payload = b""
        return resp_type, status_byte, payload

    def _poll_loop(self, stop):
        """Interruptible keepalive; never reuse a subsequent session's event."""
        while not stop.wait(2.0):
            try:
                self._send_control_cmd(CMD_HEARTBEAT, b"")
                if not self.is_tcp_media and self._media_sock:
                    # Remote UDP port is the service port, NOT the local media port.
                    self._media_sock.sendto(b"\x00\x04\x00\x00", (self.host, self.control_port))
            except Exception as exc:
                self._stream_failed(stop, f"Heartbeat failed: {exc}")
                return

    def _stream_failed(self, stop, detail):
        # Never block on the lifecycle lock while its owner may be joining us.
        if stop.is_set():
            return
        if self._lifecycle_lock.acquire(blocking=False):
            try:
                if stop is self._stop_event and not stop.is_set():
                    self.last_error = f"{detail}. {RECOVERY_HINT}"
                    self._cleanup()
                    self._set_state(ConnectionState.ERROR, self.last_error)
            finally:
                self._lifecycle_lock.release()
        else:
            # connect()/disconnect() owns cleanup. A just-started worker can
            # fail before connect releases the lock; retry acquisition only
            # while this session is live (the owner signals stop before join).
            while not stop.wait(0.01):
                if self._lifecycle_lock.acquire(blocking=False):
                    try:
                        self._stream_failed(stop, detail)
                    finally:
                        self._lifecycle_lock.release()
                    return

    def _media_udp_loop(self, sock, stop):
        """Receive on the socket already bound before codec negotiation."""
        try:
            sock.sendto(b"\x00\x04\x00\x00", (self.host, self.control_port))
            while not stop.is_set():
                try:
                    packet, addr = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                if not stop.is_set() and len(packet) > 7:
                    self._process_media_packet(packet)
        except Exception as exc:
            self._stream_failed(stop, f"UDP media stream error: {exc}")

    def _media_tcp_loop(self, sock, stop):
        """Receive streaming audio; short socket waits allow prompt cancellation."""
        try:
            while not stop.is_set():
                header = self._read_exact(sock, 11, stop=stop)
                ver, total_len, seq, timestamp, flags = struct.unpack(">HHHIb", header)
                if total_len < 7:
                    raise ConnectionError(f"Invalid media frame length: {total_len}")
                payload_len = total_len - 7
                if payload_len > 0:
                    payload = self._read_exact(sock, payload_len, stop=stop)
                    if not stop.is_set():
                        self._decode_and_play(payload)
        except Exception as exc:
            self._stream_failed(stop, f"TCP media stream error: {exc}")

    def _process_media_packet(self, packet: bytes):
        """Parses an 11-byte header UDP media packet and decodes Opus frame."""
        # Packet format (frame layout documented from observed network behaviour):
        # [proto_ver (2 BE)] [data_len (2 BE)] [seq (2 BE)] [timestamp (4 BE)] [flag (1)] [Opus payload]
        # data_len = len(seq + ts + flag + opus_payload) = opus_len + 7
        try:
            if len(packet) < UDP_MEDIA_HEADER_SIZE:
                return

            ver = struct.unpack(">H", packet[:2])[0]
            if ver != PROTOCOL_VERSION_V4_BE:
                return

            data_len = struct.unpack(">H", packet[2:4])[0]
            seq = struct.unpack(">H", packet[4:6])[0]
            timestamp = struct.unpack(">I", packet[6:10])[0]
            flag = packet[10]

            # Opus payload starts at byte 11
            payload = packet[UDP_MEDIA_HEADER_SIZE:]
            
            self._packets_received += 1
            self._bytes_received += len(payload)
            self._last_seq = seq
            
            self._decode_and_play(payload)

        except Exception:
            pass

    def _decode_and_play(self, opus_payload: bytes):
        """Decodes an Opus packet to PCM and passes to AudioOutputEngine."""
        with self._decode_lock:
            if not opus_payload or not self.decoder:
                return
            try:
                pcm = self.decoder.decode(opus_payload)
                if pcm and self.audio_engine:
                    self.audio_engine.write_pcm(pcm)
            except Exception:
                pass

    @staticmethod
    def _abort_socket(sock, send_stop=False):
        """Best-effort 0x68 then RST. Do NOT shutdown first (that sends FIN).

        RST cannot guarantee remote application recovery or delivery of 0x68,
        particularly through a TCP proxy such as adb forward.
        """
        if sock is None:
            return
        try:
            if send_stop:
                try:
                    sock.settimeout(0.2)
                    sock.sendall(struct.pack(">BI", CMD_STOP_CAPTURE, 0))
                except OSError:
                    pass
            if sock.type & socket.SOCK_STREAM:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        except OSError:
            pass
        finally:
            try:
                sock.close()
            except OSError:
                pass

    def _cleanup(self):
        """Called under lifecycle lock; stop old workers before releasing decoder."""
        self._is_running = False
        self._stop_event.set()
        with self._send_lock:
            control, self._control_sock = self._control_sock, None
            self._abort_socket(control, send_stop=True)
        media, self._media_sock = self._media_sock, None
        self._abort_socket(media)
        current = threading.current_thread()
        for name in ("_worker_thread", "_poll_thread"):
            worker = getattr(self, name)
            if worker is not None and worker is not current and worker.ident is not None:
                worker.join(timeout=1.5)
            setattr(self, name, None)
        with self._decode_lock:
            if self.decoder:
                try:
                    self.decoder.close()
                except Exception:
                    pass
                finally:
                    self.decoder = None
        if self.audio_engine:
            try:
                self.audio_engine.stop()
            except Exception:
                pass

    def disconnect(self):
        """Cancel retries, abort sockets, and clean up workers/audio/decoder."""
        # Signal before taking the lock so backoff/read deadlines stay bounded.
        self._cancel_connect.set()
        self._stop_event.set()
        with self._lifecycle_lock:
            self._cleanup()
            self._set_state(ConnectionState.DISCONNECTED, "Disconnected")
