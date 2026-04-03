package lime._internal.backend.native;

import haxe.io.Bytes;
import haxe.Int64;
import haxe.Timer;
import lime.math.Vector4;
import lime.media.openal.AL;
import lime.media.openal.ALBuffer;
import lime.media.openal.ALSource;
import lime.media.vorbis.VorbisFile;
import lime.media.AudioManager;
import lime.media.AudioSource;
import lime.system.CFFIPointer;
import lime.utils.UInt8Array;

#if !lime_debug
@:fileXml('tags="haxe,release"')
@:noDebug
#end
@:access(lime._internal.backend.native.NativeCFFI)
@:access(lime.media.AudioBuffer)
class NativeAudioSource
{
	private static var STREAM_BUFFER_SIZE = 48000;
	#if (native_audio_buffers && !macro)
	private static var STREAM_NUM_BUFFERS = Std.parseInt(haxe.macro.Compiler.getDefine("native_audio_buffers"));
	#else
	private static var STREAM_NUM_BUFFERS = 3;
	#end
	private static var STREAM_TIMER_FREQUENCY = 100;

	#if lime_openalsoft
	private static var hasDirectChannelsExt:Null<Bool>;
	#end

	private var buffers:Array<ALBuffer>;
	private var bufferTimeBlocks:Array<Float>;
	private var completed:Bool;
	private var dataLength:Int;
	private var format:Int;
	private var handle:ALSource;
	private var length:Null<Float>;
	private var loops:Int;
	private var parent:AudioSource;
	private var playing:Bool;
	private var position:Vector4;
	private var queuedBufferCount:Int;
	private var readArray:UInt8Array;
	private var readBuffer:Bytes;
	private var sdlSoundStream:CFFIPointer;
	private var samples:Int;
	private var stream:Bool;
	private var streamByteRate:Float;
	private var streamCanSeek:Bool;
	private var streamExhausted:Bool;
	private var streamPosition:Float;
	private var streamTimer:Timer;
	private var timer:Timer;

	public function new(parent:AudioSource)
	{
		this.parent = parent;

		position = new Vector4();
	}

	public function dispose():Void
	{
		if (handle != null)
		{
			stop();
			AL.sourcei(handle, AL.BUFFER, null);
			AL.deleteSource(handle);
			if (buffers != null)
			{
				for (buffer in buffers)
				{
					AL.deleteBuffer(buffer);
				}
				buffers = null;
			}
			handle = null;
		}

		clearSDLSoundStream();
	}

	public function init():Void
	{
		dataLength = 0;
		format = 0;
		stream = false;
		streamByteRate = 0;
		streamCanSeek = false;
		streamExhausted = false;
		streamPosition = 0;
		queuedBufferCount = 0;

		if (parent.buffer.channels == 1)
		{
			if (parent.buffer.bitsPerSample == 8)
			{
				format = AL.FORMAT_MONO8;
			}
			else if (parent.buffer.bitsPerSample == 16)
			{
				format = AL.FORMAT_MONO16;
			}
		}
		else if (parent.buffer.channels == 2)
		{
			if (parent.buffer.bitsPerSample == 8)
			{
				format = AL.FORMAT_STEREO8;
			}
			else if (parent.buffer.bitsPerSample == 16)
			{
				format = AL.FORMAT_STEREO16;
			}
		}

		streamByteRate = parent.buffer.sampleRate * parent.buffer.channels * (parent.buffer.bitsPerSample / 8);

		if (hasSDLSoundStreamSource())
		{
			if (openSDLSoundStream())
			{
				stream = true;
				if (parent.buffer.__srcSDLSoundDuration > 0)
				{
					dataLength = Std.int(Math.ceil(parent.buffer.__srcSDLSoundDuration * streamByteRate / 1000));
					dataLength = alignStreamRequestLength(dataLength);
				}
				else
				{
					dataLength = -1;
				}

				buffers = new Array();
				bufferTimeBlocks = new Array();

				for (i in 0...STREAM_NUM_BUFFERS)
				{
					buffers.push(AL.createBuffer());
					bufferTimeBlocks.push(0);
				}

				handle = AL.createSource();
			}
			else if (parent.buffer.__srcVorbisFile == null && parent.buffer.data == null)
			{
				handle = null;
				return;
			}
		}

		if (!stream && parent.buffer.__srcVorbisFile != null)
		{
			stream = true;

			var vorbisFile = parent.buffer.__srcVorbisFile;
			dataLength = Std.int(Int64.toInt(vorbisFile.pcmTotal()) * parent.buffer.channels * (parent.buffer.bitsPerSample / 8));

			buffers = new Array();
			bufferTimeBlocks = new Array();

			for (i in 0...STREAM_NUM_BUFFERS)
			{
				buffers.push(AL.createBuffer());
				bufferTimeBlocks.push(0);
			}

			handle = AL.createSource();
		}
		else if (!stream)
		{
			if (parent.buffer.__srcBuffer == null)
			{
				parent.buffer.__srcBuffer = AL.createBuffer();

				if (parent.buffer.__srcBuffer != null)
				{
					AL.bufferData(parent.buffer.__srcBuffer, format, parent.buffer.data, parent.buffer.data.length, parent.buffer.sampleRate);
				}
			}

			dataLength = parent.buffer.data.length;

			handle = AL.createSource();

			if (handle != null)
			{
				AL.sourcei(handle, AL.BUFFER, parent.buffer.__srcBuffer);
			}
		}

		#if lime_openalsoft
		if (hasDirectChannelsExt == null)
		{
			hasDirectChannelsExt = AL.isExtensionPresent("AL_SOFT_direct_channels") && AL.isExtensionPresent("AL_SOFT_direct_channels_remix");
		}

		if (hasDirectChannelsExt)
		{
			AL.sourcei(handle, AL.DIRECT_CHANNELS_SOFT, AL.REMIX_UNMATCHED_SOFT);
		}
		#end

		if (dataLength > 0)
		{
			samples = Std.int((dataLength * 8.0) / (parent.buffer.channels * parent.buffer.bitsPerSample));
		}
		else
		{
			samples = 0;
		}
	}

	public function play():Void
	{
		if (playing || handle == null)
		{
			return;
		}

		playing = true;

		if (stream)
		{
			var time = completed ? 0.0 : getCurrentTime();
			setCurrentTime(time);

			streamTimer = new Timer(STREAM_TIMER_FREQUENCY);
			streamTimer.run = streamTimer_onRun;
		}
		else
		{
			var time = completed ? 0.0 : getCurrentTime();
			setCurrentTime(time);
		}
	}

	public function pause():Void
	{
		playing = false;

		if (handle == null) return;
		AL.sourcePause(handle);

		if (streamTimer != null)
		{
			streamTimer.stop();
		}

		if (timer != null)
		{
			timer.stop();
		}
	}

	private function clearSDLSoundStream():Void
	{
		#if lime_sdl_sound
		if (sdlSoundStream != null)
		{
			NativeCFFI.lime_sdl_sound_stream_clear(sdlSoundStream);
			sdlSoundStream = null;
		}
		#end
	}

	private function hasSDLSoundStreamSource():Bool
	{
		return parent.buffer != null && (parent.buffer.__srcSDLSoundBytes != null || parent.buffer.__srcSDLSoundPath != null);
	}

	private function openSDLSoundStream():Bool
	{
		#if lime_sdl_sound
		clearSDLSoundStream();

		if (parent.buffer.__srcSDLSoundBytes != null)
		{
			sdlSoundStream = NativeCFFI.lime_sdl_sound_stream_from_bytes(parent.buffer.__srcSDLSoundBytes);
		}
		else if (parent.buffer.__srcSDLSoundPath != null)
		{
			sdlSoundStream = NativeCFFI.lime_sdl_sound_stream_from_file(parent.buffer.__srcSDLSoundPath);
		}

		if (sdlSoundStream != null)
		{
			streamCanSeek = parent.buffer.__srcSDLSoundCanSeek;
			streamExhausted = false;
			streamPosition = 0;
			return true;
		}
		#end

		return false;
	}

	private function resetSDLSoundStream(time:Int):Bool
	{
		#if lime_sdl_sound
		if (time < 0)
		{
			time = 0;
		}

		if (sdlSoundStream == null && !openSDLSoundStream())
		{
			return false;
		}

		if (time == 0)
		{
			if (streamCanSeek && NativeCFFI.lime_sdl_sound_stream_rewind(sdlSoundStream))
			{
				streamExhausted = false;
				streamPosition = 0;
				return true;
			}

			return openSDLSoundStream();
		}

		if (streamCanSeek && NativeCFFI.lime_sdl_sound_stream_seek(sdlSoundStream, time))
		{
			streamExhausted = false;
			streamPosition = time / 1000;
			return true;
		}
		#end

		return false;
	}

	private function shiftBufferTimeBlocks(time:Float):Void
	{
		for (i in 0...STREAM_NUM_BUFFERS - 1)
		{
			bufferTimeBlocks[i] = bufferTimeBlocks[i + 1];
		}

		bufferTimeBlocks[STREAM_NUM_BUFFERS - 1] = time;
	}

	private function alignStreamRequestLength(length:Int):Int
	{
		var frameSize = Std.int(parent.buffer.channels * (parent.buffer.bitsPerSample / 8));

		if (frameSize <= 0 || length <= frameSize)
		{
			return length;
		}

		return length - (length % frameSize);
	}

	private function clearQueuedBuffers():Void
	{
		if (handle == null)
		{
			queuedBufferCount = 0;
			return;
		}

		var queued = AL.getSourcei(handle, AL.BUFFERS_QUEUED);

		if (queued > 0)
		{
			AL.sourceUnqueueBuffers(handle, queued);
		}

		queuedBufferCount = 0;
	}

	private function ensureReadBuffer(length:Int):Bool
	{
		if (length <= 0)
		{
			return false;
		}

		if (readBuffer == null || readBuffer.length < length)
		{
			readBuffer = Bytes.alloc(length);
			readArray = UInt8Array.fromBytes(readBuffer);
		}

		return true;
	}

	private function readSDLSoundBuffer(length:Int):Int
	{
		#if lime_sdl_sound
		if (sdlSoundStream == null || length <= 0)
		{
			return 0;
		}

		if (!ensureReadBuffer(length))
		{
			return 0;
		}

		var read = NativeCFFI.lime_sdl_sound_stream_read(sdlSoundStream, readBuffer, length);

		if (read <= 0)
		{
			return read;
		}

		shiftBufferTimeBlocks(streamPosition);
		streamPosition += read / streamByteRate;
		return read;
		#else
		return 0;
		#end
	}

	private function readVorbisFileBuffer(vorbisFile:VorbisFile, length:Int):Int
	{
		#if lime_vorbis
		if (!ensureReadBuffer(length))
		{
			return 0;
		}

		var read = 0, total = 0, readMax;
		shiftBufferTimeBlocks(vorbisFile.timeTell());

		while (total < length)
		{
			readMax = 4096;

			if (readMax > length - total)
			{
				readMax = length - total;
			}

			read = vorbisFile.read(readBuffer, total, readMax);

			if (read > 0)
			{
				total += read;
			}
			else
			{
				break;
			}
		}

		return total;
		#else
		return 0;
		#end
	}

	private function refillBuffers(buffers:Array<ALBuffer> = null):Void
	{
		var useSDLSound = hasSDLSoundStreamSource();
		var hasKnownStreamLength = (dataLength > 0);
		var vorbisFile = null;
		var position = 0;

		if (buffers == null)
		{
			var buffersProcessed:Int = AL.getSourcei(handle, AL.BUFFERS_PROCESSED);

			if (buffersProcessed > 0)
			{
				if (useSDLSound)
				{
					position = Std.int(streamPosition * streamByteRate);
				}
				else
				{
					#if lime_vorbis
					vorbisFile = parent.buffer.__srcVorbisFile;
					position = Int64.toInt(vorbisFile.pcmTell());
					#end
				}

				if (!hasKnownStreamLength || position < dataLength || streamExhausted)
				{
					buffers = AL.sourceUnqueueBuffers(handle, buffersProcessed);

					if (buffers != null)
					{
						queuedBufferCount -= buffers.length;
					}
					else
					{
						queuedBufferCount -= buffersProcessed;
					}

					if (queuedBufferCount < 0)
					{
						queuedBufferCount = 0;
					}
				}
			}
		}

		if (buffers != null)
		{
			if (!useSDLSound)
			{
				#if lime_vorbis
				if (vorbisFile == null)
				{
					vorbisFile = parent.buffer.__srcVorbisFile;
					position = Int64.toInt(vorbisFile.pcmTell());
				}
				#end
			}
			else
			{
				position = Std.int(streamPosition * streamByteRate);
			}

			var numBuffers = 0;
			var bytesRead = 0;

			for (buffer in buffers)
			{
				if (hasKnownStreamLength && position >= dataLength)
				{
					streamExhausted = true;
					break;
				}

				var requestLength = hasKnownStreamLength ? (dataLength - position) : STREAM_BUFFER_SIZE;

				if (requestLength > STREAM_BUFFER_SIZE)
				{
					requestLength = STREAM_BUFFER_SIZE;
				}

				requestLength = alignStreamRequestLength(requestLength);

				if (useSDLSound)
				{
					bytesRead = readSDLSoundBuffer(requestLength);
				}
				else
				{
					#if lime_vorbis
					bytesRead = readVorbisFileBuffer(vorbisFile, requestLength);
					#else
					bytesRead = 0;
					#end
				}

				if (bytesRead <= 0 || readArray == null)
				{
					streamExhausted = true;
					break;
				}

				AL.bufferData(buffer, format, readArray, bytesRead, parent.buffer.sampleRate);
				position += bytesRead;
				numBuffers++;

				if (bytesRead < requestLength)
				{
					streamExhausted = true;
					break;
				}
			}

			if (numBuffers > 0)
			{
				var buffersToQueue = (numBuffers == buffers.length) ? buffers : buffers.slice(0, numBuffers);
				AL.sourceQueueBuffers(handle, numBuffers, buffersToQueue);
				queuedBufferCount += numBuffers;
			}

			// OpenAL can unexpectedly stop playback if the buffers run out
			// of data, which typically happens if an operation (such as
			// resizing a window) freezes the main thread.
			// If AL is supposed to be playing but isn't, restart it here.
			if (playing && handle != null && queuedBufferCount > 0 && AL.getSourcei(handle, AL.SOURCE_STATE) == AL.STOPPED)
			{
				AL.sourcePlay(handle);
			}
		}
	}

	public function stop():Void
	{
		if (playing && handle != null && AL.getSourcei(handle, AL.SOURCE_STATE) == AL.PLAYING)
		{
			AL.sourceStop(handle);
		}

		playing = false;

		if (streamTimer != null)
		{
			streamTimer.stop();
		}

		if (timer != null)
		{
			timer.stop();
		}

		setCurrentTime(0);
	}

	// Event Handlers
	private function streamTimer_onRun():Void
	{
		refillBuffers();

		if (playing && timer == null && streamExhausted && queuedBufferCount == 0 && handle != null && AL.getSourcei(handle, AL.SOURCE_STATE) != AL.PLAYING)
		{
			if (length == null && parent.buffer.__srcSDLSoundDuration <= 0)
			{
				length = streamPosition * 1000 - parent.offset;
				if (length < 0)
				{
					length = 0;
				}
			}

			timer_onRun();
		}
	}

	private function timer_onRun():Void
	{
		if (loops > 0)
		{
			playing = false;
			loops--;
			setCurrentTime(0);
			play();
			return;
		}
		else
		{
			playing = false;
			stop();
		}

		completed = true;
		parent.onComplete.dispatch();
	}

	// Get & Set Methods
	public function getCurrentTime():Float
	{
		if (completed)
		{
			return getLength();
		}
		else if (handle != null)
		{
			if (stream)
			{
				var time = (bufferTimeBlocks[0] * 1000 + AL.getSourcef(handle, AL.SEC_OFFSET) * 1000) - parent.offset;
				if (time < 0) return 0;
				return time;
			}
			else
			{
				var sec_offset:Float = AL.getSourcef(handle, AL.SEC_OFFSET);
				var time = sec_offset * 1000 - parent.offset;
				if (time < 0) return 0;
				return time;
			}
		}

		return 0;
	}

	public function setCurrentTime(value:Float):Float
	{
		if (handle != null)
		{
			if (stream)
			{
				AL.sourceStop(handle);
				var streamTime = Std.int(value + parent.offset);

				if (hasSDLSoundStreamSource())
				{
					if (!resetSDLSoundStream(streamTime))
					{
						value = 0;
						streamTime = Std.int(parent.offset);
						resetSDLSoundStream(streamTime);
					}
				}
				else
				{
					#if lime_vorbis
					parent.buffer.__srcVorbisFile.timeSeek((value + parent.offset) / 1000);
					#end
				}

				clearQueuedBuffers();

				for (i in 0...STREAM_NUM_BUFFERS)
				{
					bufferTimeBlocks[i] = 0;
				}

				refillBuffers(buffers);

				if (playing)
				{
					AL.sourcePlay(handle);
				}
			}
			else if (parent.buffer != null)
			{
				var total = samples / parent.buffer.sampleRate * 1000;
				var time = Math.max(0, Math.min(total, value + parent.offset));
				var ratio = time / total;

				AL.sourceRewind(handle);
				AL.sourcef(handle, AL.SEC_OFFSET, time/1000);
				//AL.sourcei(handle, AL.BYTE_OFFSET, Std.int(dataLength * ratio));
				if (playing) AL.sourcePlay(handle);
			}
		}

		if (playing)
		{
			if (timer != null)
			{
				timer.stop();
			}

			var totalLength = getLength();
			var timeRemaining = (totalLength - value) / getPitch();

			if (timeRemaining > 0)
			{
				completed = false;
				timer = new Timer(timeRemaining);
				timer.run = timer_onRun;
			}
			else if (stream && totalLength <= 0)
			{
				completed = false;
				timer = null;
			}
			else
			{
				playing = false;
				completed = true;
			}
		}

		return value;
	}

	public function getGain():Float
	{
		if (handle != null)
		{
			return AL.getSourcef(handle, AL.GAIN);
		}
		else
		{
			return 1;
		}
	}

	public function setGain(value:Float):Float
	{
		if (handle != null)
		{
			AL.sourcef(handle, AL.GAIN, value);
		}

		return value;
	}

	public function getLength():Float
	{
		if (length != null)
		{
			return length;
		}

		if (stream && hasSDLSoundStreamSource() && parent.buffer.__srcSDLSoundDuration > 0)
		{
			return parent.buffer.__srcSDLSoundDuration - parent.offset;
		}

		return (samples / parent.buffer.sampleRate * 1000) - parent.offset;
	}

	public function setLength(value:Float):Float
	{
		if (playing && length != value)
		{
			if (timer != null)
			{
				timer.stop();
			}

			var timeRemaining = (value - getCurrentTime()) / getPitch();

			if (timeRemaining > 0)
			{
				timer = new Timer(timeRemaining);
				timer.run = timer_onRun;
			}
		}

		return length = value;
	}

	public function getLoops():Int
	{
		return loops;
	}

	public function setLoops(value:Int):Int
	{
		return loops = value;
	}

	public function getPitch():Float
	{
		if (handle != null)
		{
			return AL.getSourcef(handle, AL.PITCH);
		}
		else
		{
			return 1;
		}
	}

	public function setPitch(value:Float):Float
	{
		if (playing && value != getPitch())
		{
			if (timer != null)
			{
				timer.stop();
			}

			var totalLength = getLength();
			var timeRemaining = (totalLength - getCurrentTime()) / value;

			if (timeRemaining > 0)
			{
				timer = new Timer(timeRemaining);
				timer.run = timer_onRun;
			}
			else
			{
				timer = null;
			}
		}

		if (handle != null)
		{
			AL.sourcef(handle, AL.PITCH, value);
		}

		return value;
	}

	public function getPosition():Vector4
	{
		if (handle != null)
		{
			#if !webassembly
			var value = AL.getSource3f(handle, AL.POSITION);
			position.x = value[0];
			position.y = value[1];
			position.z = value[2];
			#end
		}

		return position;
	}

	public function setPosition(value:Vector4):Vector4
	{
		position.x = value.x;
		position.y = value.y;
		position.z = value.z;
		position.w = value.w;

		if (handle != null)
		{
			AL.distanceModel(AL.NONE);
			AL.source3f(handle, AL.POSITION, position.x, position.y, position.z);
		}

		return position;
	}
}
