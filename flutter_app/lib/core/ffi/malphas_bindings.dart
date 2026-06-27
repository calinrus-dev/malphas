import 'dart:ffi' as dffi;
import 'dart:io';
import 'package:ffi/ffi.dart' as ffi;
import 'types.dart';

class MalphasBindings {
  static const int maxCommandBufferCapacity = 2048;

  late final dffi.DynamicLibrary _nativeLib;

  late final int Function(dffi.Pointer<dffi.Void>) initEngine;
  late final int Function(int, double, double) processInputEvent;
  late final int Function(dffi.Pointer<DartRenderCommand>, int) renderTick;

  dffi.Pointer<DartCommandBuffer>? _commandBuffer = dffi.nullptr;
  dffi.Pointer<DartRenderCommand>? _renderCommands = dffi.nullptr;

  MalphasBindings() {
    _loadLibrary();
    _linkFunctions();
    _initializeSharedMemory();
  }

  void _loadLibrary() {
    if (Platform.isAndroid) {
      _nativeLib = dffi.DynamicLibrary.open('libmalphas_core.so');
    } else if (Platform.isWindows) {
      _nativeLib = dffi.DynamicLibrary.open('malphas_core.dll');
    } else if (Platform.isLinux || Platform.isMacOS) {
      _nativeLib = dffi.DynamicLibrary.open('libmalphas_core.so');
    } else {
      throw UnsupportedError('Plataforma no soportada en el chasis FFI');
    }
  }

  void _linkFunctions() {
    initEngine = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(dffi.Pointer<dffi.Void>)>>('init_engine')
        .asFunction();

    processInputEvent = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(
                    dffi.Int32, dffi.Float, dffi.Float)>>('process_input_event')
        .asFunction();

    renderTick = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(dffi.Pointer<DartRenderCommand>,
                    dffi.Int32)>>('render_tick')
        .asFunction();
  }

  void _initializeSharedMemory() {
    final buffer = ffi.calloc<DartCommandBuffer>();
    if (buffer == dffi.nullptr) {
      throw Exception('Fallo asignando DartCommandBuffer en heap');
    }

    final commands = ffi.calloc<DartRenderCommand>(maxCommandBufferCapacity);
    if (commands == dffi.nullptr) {
      ffi.calloc.free(buffer);
      throw Exception('Fallo asignando DartRenderCommand array en heap');
    }

    buffer.ref.commandCount = 0;
    buffer.ref.commands = commands;

    _commandBuffer = buffer;
    _renderCommands = commands;

    final res = initEngine(buffer.cast<dffi.Void>());
    if (res != 0) {
      ffi.calloc.free(commands.cast());
      ffi.calloc.free(buffer.cast());
      _commandBuffer = dffi.nullptr;
      _renderCommands = dffi.nullptr;
      throw Exception('init_engine devolvió código de error: $res');
    }
  }

  dffi.Pointer<DartCommandBuffer>? get commandBuffer => _commandBuffer;

  int tick() {
    if (_renderCommands == null || _renderCommands == dffi.nullptr) {
      return 0;
    }

    final rawCount = renderTick(_renderCommands!, maxCommandBufferCapacity);

    var count = rawCount;
    if (count < 0) count = 0;
    if (count > maxCommandBufferCapacity) count = maxCommandBufferCapacity;

    if (_commandBuffer != null && _commandBuffer != dffi.nullptr) {
      try {
        _commandBuffer!.ref.commandCount = count;
      } catch (_) {}
    }

    return count;
  }

  int sendInputEvent(int eventType, double x, double y) {
    if (eventType < 0 || eventType > 0x7fffffff) return -1;
    if (x.isNaN || y.isNaN) return -2;
    return processInputEvent(eventType, x, y);
  }

  void dispose() {
    if (_renderCommands != null && _renderCommands != dffi.nullptr) {
      try {
        ffi.calloc.free(_renderCommands!.cast());
      } catch (_) {}
      _renderCommands = dffi.nullptr;
    }

    if (_commandBuffer != null && _commandBuffer != dffi.nullptr) {
      try {
        ffi.calloc.free(_commandBuffer!.cast());
      } catch (_) {}
      _commandBuffer = dffi.nullptr;
    }
  }
}
