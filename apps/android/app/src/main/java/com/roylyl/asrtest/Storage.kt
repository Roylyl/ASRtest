package com.roylyl.asrtest

import android.content.Context
import android.os.Build
import android.os.Debug
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

class ModelStore(private val context: Context) {
    private val root = File(context.filesDir, "ModelLibrary")
    @Synchronized fun ensure(model: ModelSpec, progress: (String) -> Unit): File {
        val dest = File(root, model.id)
        copyAssets("ModelLibrary/${model.id}", dest, progress)
        return dest
    }
    private fun copyAssets(path: String, destination: File, progress: (String) -> Unit) {
        val children = context.assets.list(path) ?: emptyArray()
        if (children.isNotEmpty()) {
            destination.mkdirs()
            children.filter { !it.startsWith(".") }.forEach { copyAssets("$path/$it", File(destination,it), progress) }
        } else {
            if (destination.isFile && destination.length() > 0) return
            destination.parentFile?.mkdirs(); progress("首次准备本地模型：${destination.name}")
            val tmp = File(destination.parentFile, destination.name + ".tmp")
            context.assets.open(path).use { input -> tmp.outputStream().use { input.copyTo(it, 1024*1024) } }
            check(tmp.renameTo(destination)) { "无法写入本地模型：${destination.name}" }
        }
    }
    fun bytes(model: ModelSpec): Long = File(root, model.id).walkTopDown().filter { it.isFile }.sumOf { it.length() }
}

object WavIO {
    fun read(file: File, maxSeconds: Int = 600): FloatArray {
        java.io.RandomAccessFile(file,"r").use { f ->
            val header = ByteArray(12); f.readFully(header)
            require(String(header,0,4)=="RIFF" && String(header,8,4)=="WAVE") { "仅支持RIFF WAV" }
            var format = 0; var channels = 0; var rate = 0; var bits = 0; var dataOffset = 0L; var dataSize = 0L
            while (f.filePointer + 8 <= f.length()) {
                val id = ByteArray(4); f.readFully(id)
                val size = java.lang.Integer.reverseBytes(f.readInt()).toLong() and 0xffffffffL
                val start = f.filePointer; require(start + size <= f.length()) { "WAV数据不完整" }
                when (String(id)) {
                    "fmt " -> { require(size >= 16); format = java.lang.Short.reverseBytes(f.readShort()).toInt() and 65535
                        channels = java.lang.Short.reverseBytes(f.readShort()).toInt() and 65535
                        rate = java.lang.Integer.reverseBytes(f.readInt()); f.skipBytes(6)
                        bits = java.lang.Short.reverseBytes(f.readShort()).toInt() and 65535 }
                    "data" -> { dataOffset = start; dataSize = size }
                }
                f.seek(start + size + (size and 1))
            }
            require(format in listOf(1,3) && channels in 1..8 && rate in 8000..192000 && bits in listOf(8,16,24,32)) { "不支持的WAV格式" }
            require(format != 3 || bits == 32) { "浮点WAV须为32位" }
            val frames = dataSize / (channels * bits/8); require(frames > 0 && frames <= rate.toLong()*maxSeconds) { "音频为空或超过${maxSeconds}秒限制" }
            f.seek(dataOffset); val pcm = FloatArray((frames*16000/rate).toInt()); val stride = channels*bits/8
            val block = ByteArray(4096*stride); var offset = 0
            var sourceIndex=0L;var targetIndex=0;var previous=0f
            while (sourceIndex < frames) {
                val n = minOf(4096L,frames-sourceIndex).toInt(); f.readFully(block,0,n*stride)
                val b=ByteBuffer.wrap(block).order(ByteOrder.LITTLE_ENDIAN)
                repeat(n) { var sum=0f; repeat(channels) {
                    sum += if (format==3) b.float else when(bits) {
                        8 -> ((b.get().toInt() and 255)-128)/128f
                        16 -> b.short/32768f
                        24 -> { val v=(b.get().toInt() and 255) or ((b.get().toInt() and 255) shl 8) or (b.get().toInt() shl 16); v/8388608f }
                        else -> b.int/2147483648f
                    }
                }; val value=(sum/channels).also { require(it.isFinite()) { "音频含无效采样" } }
                    while(targetIndex<pcm.size && targetIndex.toDouble()*rate/16000<=sourceIndex) {
                        val position=targetIndex.toDouble()*rate/16000
                        val fraction=(position-(sourceIndex-1)).toFloat().coerceIn(0f,1f)
                        pcm[targetIndex++]=if(sourceIndex==0L)value else previous*(1-fraction)+value*fraction
                    };previous=value;sourceIndex++
                }
            }
            while(targetIndex<pcm.size)pcm[targetIndex++]=previous
            return pcm
        }
    }
    fun write(file: File, pcm: FloatArray) {
        file.parentFile?.mkdirs()
        file.outputStream().use { o ->
            val b=ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            b.put("RIFF".toByteArray()).putInt(36+pcm.size*2).put("WAVEfmt ".toByteArray()).putInt(16)
                .putShort(1).putShort(1).putInt(16000).putInt(32000).putShort(2).putShort(16)
                .put("data".toByteArray()).putInt(pcm.size*2); o.write(b.array())
            val block=ByteBuffer.allocate(8192).order(ByteOrder.LITTLE_ENDIAN)
            pcm.forEach { if(block.remaining()<2) { o.write(block.array(),0,block.position());block.clear() }; block.putShort((it.coerceIn(-1f,1f)*32767).toInt().toShort()) }
            o.write(block.array(),0,block.position())
        }
    }
}

class MemorySampler {
    private val running=AtomicBoolean(false)
    @Volatile var peakRssKB=0L; private set
    val baselineRssKB: Long = rss()
    private var thread: Thread?=null
    fun start() { peakRssKB=baselineRssKB;running.set(true);thread=Thread {
        while(running.get()) { peakRssKB=max(peakRssKB,rss()); try { Thread.sleep(100) } catch(_:InterruptedException){} }
    }.apply { isDaemon=true;start() } }
    fun stop() { running.set(false);thread?.interrupt();thread?.join(300);peakRssKB=max(peakRssKB,rss()) }
    companion object {
        fun rss(): Long = try { File("/proc/self/status").useLines { lines -> lines.firstOrNull { it.startsWith("VmRSS:") }?.trim()?.split(Regex("\\s+"))?.get(1)?.toLong() ?: 0L } } catch(_:Exception) { 0L }
        fun pss(): Int = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss
        fun device()=JSONObject().put("manufacturer",Build.MANUFACTURER).put("model",Build.MODEL)
            .put("android",Build.VERSION.RELEASE).put("sdk",Build.VERSION.SDK_INT)
            .put("abis",Build.SUPPORTED_ABIS.joinToString()).put("hardware",Build.HARDWARE)
    }
}

object Metrics {
    private fun edit(a: List<String>, b: List<String>): Int {
        var row=IntArray(b.size+1){it}
        for(i in a.indices) { val next=IntArray(b.size+1);next[0]=i+1
            for(j in b.indices) next[j+1]=minOf(next[j]+1,row[j+1]+1,row[j]+if(a[i]==b[j])0 else 1)
            row=next
        };return row.last()
    }
    fun evaluate(reference: String, hypothesis: String, language: String): JSONObject {
        fun chars(s:String)=s.lowercase().filter { it.isLetterOrDigit() }.map { it.toString() }
        fun words(s:String)=Regex("[a-z0-9]+(?:'[a-z]+)?").findAll(s.lowercase()).map { it.value }.toList()
        val a=if(language=="en")words(reference) else chars(reference)
        val b=if(language=="en")words(hypothesis) else chars(hypothesis)
        val name=if(language=="en") "WER" else if(language=="mixed") "CER（混合字符）" else "CER"
        return JSONObject().put("metric",name).put("referenceUnits",a.size).put("editDistance",edit(a,b))
            .put("errorRate",if(a.isEmpty())JSONObject.NULL else edit(a,b).toDouble()/a.size)
    }
}

class ResultStore(private val context: Context) {
    val directory=File(context.filesDir,"results").apply{mkdirs()}
    @Synchronized fun save(group:JSONObject, marker:String?=null) {
        val id=group.getString("id");write(File(directory,"$id.json"),group.toString(2))
        if(marker!=null)write(File(directory,"benchmark-$marker.json"),group.toString(2))
    }
    private fun write(file:File,text:String) { val tmp=File(file.parentFile,file.name+".tmp");tmp.writeText(text);check(tmp.renameTo(file)){"日志保存失败"} }
    @Synchronized fun appendEvent(id:String,event:JSONObject) { File(directory,"$id.jsonl").appendText(event.toString()+"\n") }
    @Synchronized fun groups():List<JSONObject> = directory.listFiles()?.filter { it.extension=="json" && !it.name.startsWith("benchmark-") }?.sortedByDescending { it.lastModified() }?.mapNotNull { runCatching { JSONObject(it.readText()) }.getOrNull() } ?: emptyList()
    @Synchronized fun delete(id:String) { require(id.matches(Regex("[a-zA-Z0-9-]+")));File(directory,"$id.json").delete();File(directory,"$id.jsonl").delete()
        directory.listFiles()?.filter{it.name.startsWith("benchmark-") && it.extension=="json"}?.forEach { alias ->
            if(runCatching{JSONObject(alias.readText()).optString("id")==id}.getOrDefault(false))alias.delete()
        }
    }
    @Synchronized fun clear(){directory.listFiles()?.filter{it.extension in listOf("json","jsonl") }?.forEach{it.delete()} }
    @Synchronized fun export():File {
        val zip=File(context.cacheDir,"ASRtest-logs.zip")
        java.util.zip.ZipOutputStream(zip.outputStream()).use { out ->
            directory.listFiles()?.filter{it.extension in listOf("json","jsonl") && !it.name.startsWith("benchmark-") }?.forEach { file ->
                out.putNextEntry(java.util.zip.ZipEntry("results/${file.name}"));file.inputStream().use{it.copyTo(out)};out.closeEntry()
            }
        };return zip
    }
}
