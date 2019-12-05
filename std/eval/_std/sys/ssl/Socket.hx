package sys.ssl;

import haxe.io.Bytes;
import mbedtls.*;
import eval.vm.NativeSocket;

private class SocketInput extends haxe.io.Input {
	@:allow(sys.ssl.Socket) private var socket:Socket;
	var readBuf:Bytes;

	public function new(s:Socket) {
		this.socket = s;
		readBuf = Bytes.alloc(1);
	}

	public override function readByte() {
		socket.handshake();
		var r = @:privateAccess socket.ssl.read(readBuf, 0, 1);
		if (r == -1)
			throw haxe.io.Error.Blocked;
		else if (r < 0)
			throw new haxe.io.Eof();
		return readBuf.get(0);
	}

	public override function readBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || ((pos + len) : UInt) > (buf.length : UInt))
			throw haxe.io.Error.OutsideBounds;
		socket.handshake();
		var r = @:privateAccess socket.ssl.read(buf, pos, len);
		if (r == -1)
			throw haxe.io.Error.Blocked;
		else if (r <= 0)
			throw new haxe.io.Eof();
		return r;
	}

	public override function close() {
		super.close();
		if (socket != null)
			socket.close();
	}
}

private class SocketOutput extends haxe.io.Output {
	@:allow(sys.ssl.Socket) private var socket:Socket;
	var writeBuf:Bytes;

	public function new(s:Socket) {
		this.socket = s;
		writeBuf = Bytes.alloc(1);
	}

	public override function writeByte(c:Int) {
		socket.handshake();
		writeBuf.set(0, c);
		var r = @:privateAccess socket.ssl.write(writeBuf, 0, 1);
		if (r == -1)
			throw haxe.io.Error.Blocked;
		else if (r < 0)
			throw new haxe.io.Eof();
	}

	public override function writeBytes(buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		if (pos < 0 || len < 0 || ((pos + len) : UInt) > (buf.length : UInt))
			throw haxe.io.Error.OutsideBounds;
		socket.handshake();
		var r = @:privateAccess socket.ssl.write(buf, pos, len);
		if (r == -1)
			throw haxe.io.Error.Blocked;
		else if (r < 0)
			throw new haxe.io.Eof();
		return r;
	}

	public override function close() {
		super.close();
		if (socket != null)
			socket.close();
	}
}

class Socket extends sys.net.Socket {
	public static var DEFAULT_VERIFY_CERT:Null<Bool> = true;

	public static var DEFAULT_CA:Null<Certificate>;

	private var conf:Config;
	private var ssl:Ssl;

	public var verifyCert:Null<Bool>;

	private var caCert:Null<Certificate>;
	private var hostname:String;

	private var handshakeDone:Bool;
	private var isBlocking:Bool = true;

	override function init(socket:NativeSocket) {
		this.socket = socket;
		input = new SocketInput(this);
		output = new SocketOutput(this);
		if (DEFAULT_VERIFY_CERT && DEFAULT_CA == null) {
			DEFAULT_CA = new Certificate();
			Mbedtls.loadDefaultCertificates(DEFAULT_CA);
		}
		verifyCert = DEFAULT_VERIFY_CERT;
		caCert = DEFAULT_CA;
	}

	public override function connect(host:sys.net.Host, port:Int):Void {
		conf = buildConfig(false);
		ssl = new Ssl();
		ssl.setup(conf);
		ssl.setSocket(socket);
		handshakeDone = false;
		if (hostname == null)
			hostname = host.host;
		if (hostname != null)
			ssl.set_hostname(hostname);
		socket.connect(host.ip, port);
		if (isBlocking)
			handshake();
	}

	public function handshake():Void {
		if (!handshakeDone) {
			var r = ssl.handshake();
			if (r == 0)
				handshakeDone = true;
			else if (r == -1)
				throw haxe.io.Error.Blocked;
			else
				throw mbedtls.Error.strerror(r);
		}
	}

	override function setBlocking(b:Bool):Void {
		super.setBlocking(b);
		isBlocking = b;
	}

	public function setCA(cert:Certificate):Void {
		caCert = cert;
	}

	public function setHostname(name:String):Void {
		hostname = name;
	}

	public override function close():Void {
		if (ssl != null)
			ssl.free();
		if (conf != null)
			conf.free();
		super.close();
		var input:SocketInput = cast input;
		var output:SocketOutput = cast output;
		@:privateAccess input.socket = output.socket = null;
		input.close();
		output.close();
	}

	public override function bind(host:sys.net.Host, port:Int):Void {
		conf = buildConfig(true);

		socket.bind(host.ip, port);
	}

	public override function accept():Socket {
		var c = socket.accept();
		var cssl = new Ssl();
		cssl.setup(conf);
		cssl.setSocket(c);

		var s = Type.createEmptyInstance(sys.ssl.Socket);
		s.socket = c;
		s.ssl = cssl;
		s.input = new SocketInput(s);
		s.output = new SocketOutput(s);
		s.handshakeDone = false;

		return s;
	}

	private function buildConfig(server:Bool):Config {
		var conf = new Config();
		conf.defaults(server ? SSL_IS_SERVER : SSL_IS_CLIENT, SSL_TRANSPORT_STREAM, SSL_PRESET_DEFAULT);
		conf.rng(Mbedtls.ctr);

		if (caCert != null) {
			conf.caChain(caCert);
		}
		if (!verifyCert) {}
		// conf.setVerify(if (verifyCert) 1 else if (verifyCert == null) 2 else 0);

		return conf;
	}
}