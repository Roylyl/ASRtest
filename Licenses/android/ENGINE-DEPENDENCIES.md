# Android识别后端来源
|组件|当前来源|许可与说明|
|---|---|---|
|sherpa-onnx Kotlin/JNI|本机已有官方Android验证工程，标注1.13.8；原包来自k2-fsa/sherpa-onnx|Apache-2.0。JNI包名保留com.k2fsa.sherpa.onnx；只裁掉Kotlin识别器文件末尾的示例模型预设。|
|ONNX Runtime|与上述JNI配套的arm64-v8a/libonnxruntime.so|MIT。实际版本应从运行库VersionInfo接口读取，不能把iOS框架版本直接当作Android版本。|
|Vosk Android|com.alphacephei:vosk-android:0.3.47，Maven Central官方AAR|Apache-2.0。原AAR与POM保存在app/libs/，替换了iOS社区预编译运行库；音频继续使用PCM16输入。|
|JNA Android|net.java.dev.jna:jna:5.13.0@aar，Vosk的官方依赖|Apache-2.0或LGPL-2.1-or-later双许可，本工程按Apache-2.0使用。原AAR与POM保存在app/libs/。|

运行库下载地址：
- https://repo.maven.apache.org/maven2/com/alphacephei/vosk-android/0.3.47/vosk-android-0.3.47.aar
- https://repo.maven.apache.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.aar
- https://github.com/k2-fsa/sherpa-onnx
- https://github.com/alphacep/vosk-api
- https://github.com/java-native-access/jna

直接复用iOS工程ModelLibrary/中的Zipformer Small中英INT8、SenseVoiceSmall INT8、Paraformer Streaming中英INT8、Vosk small-cn-0.22和small-en-us-0.15权重。权重许可与转换来源沿用原THIRD_PARTY_NOTICES.md；SenseVoice权重不能概括成MIT或Apache-2.0，保留原FunASR Model License及对应说明。

输入统一为16kHz单声道float[-1,1]。Zipformer、Paraformer和Vosk保留真实流式中间文字及端点终结文字，单轮上限600秒。SenseVoice在停止后调用离线识别，单轮上限30秒。Paraformer终结设置is_final=1；音频补零不计入实际音频时长。

sherpa线程参数作用于CPU运行库。Vosk0.3.47未提供每识别器线程设置API，因此选定线程数不能宣称在Vosk上生效。取消由统一工作线程持有native句柄：流式识别在块间取消；SenseVoice同步decode结束后丢弃取消的结果，不能从另一线程释放正在使用的句柄。
