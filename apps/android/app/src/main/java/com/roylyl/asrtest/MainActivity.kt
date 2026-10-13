package com.roylyl.asrtest

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.text.TextUtils
import android.view.HapticFeedbackConstants
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.OpenableColumns
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class MainActivity:Activity() {
    private val worker=Executors.newSingleThreadExecutor()
    private val stop=AtomicBoolean(false)
    private val recordStop=AtomicBoolean(false)
    private val activeEngine=AtomicReference<AsrEngine?>(null)
    private lateinit var store:ResultStore
    private lateinit var models:ModelStore
    private lateinit var root:LinearLayout
    private lateinit var content:LinearLayout
    private lateinit var statusView:TextView
    private lateinit var transcriptView:TextView
    private var selected=ModelSpec.all.first()
    private val comparison=ModelSpec.all.map{it.id}.toMutableSet()
    private var compareMode=true
    private var language="auto"
    private var threads=2
    private var itn=true
    @Volatile private var busy=false
    @Volatile private var recording=false
    private var status="模型内置·完全本地运行"
    private var transcript="识别文字和模型对比结果会显示在这里"
    private var tab=0
    private var reference=""
    private val imported=ArrayList<File>()
    private val importedNames=HashMap<String,String>()
    private var lastRecording:File?=null
    private var lastRecordingCorpus:Corpus?=null
    private var pendingBenchmark:Intent?=null
    private var destroyed=false

    override fun onCreate(state:Bundle?) {
        super.onCreate(state)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        models=ModelStore(this);store=ResultStore(this)
        val prefs=getPreferences(0)
        selected=runCatching{ModelSpec.get(prefs.getString("model","zipformer")!!)}.getOrDefault(selected)
        threads=prefs.getInt("threads",2).coerceIn(1,4)
        language=prefs.getString("language","auto")!!
        render()
        if(intent.hasExtra("benchModel"))startBenchmark(intent)
    }
    override fun onNewIntent(value:Intent) { super.onNewIntent(value);intent=value;if(value.hasExtra("benchModel"))startBenchmark(value) }
    override fun onDestroy() { destroyed=true;stop.set(true);activeEngine.get()?.cancel();worker.shutdown();super.onDestroy() }
    override fun onPause() { if(recording)stopRecording();super.onPause() }
    private val isDark get()=(resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK)==Configuration.UI_MODE_NIGHT_YES
    private val blue get()=Color.parseColor(if(isDark)"#0A84FF"else"#007AFF")
    private val canvasColor get()=Color.parseColor(if(isDark)"#000000"else"#F2F2F7")
    private val surfaceColor get()=Color.parseColor(if(isDark)"#1C1C1E"else"#FFFFFF")
    private val groupedColor get()=Color.parseColor(if(isDark)"#2C2C2E"else"#F2F2F7")
    private val inkColor get()=Color.parseColor(if(isDark)"#F5F5F7"else"#111113")
    private val secondaryColor get()=Color.parseColor(if(isDark)"#AEAEB2"else"#6C6C70")
    private val separatorColor get()=Color.parseColor(if(isDark)"#3A3A3C"else"#E5E5EA")
    private val green get()=Color.parseColor(if(isDark)"#30D158"else"#248A3D")
    private val red get()=Color.parseColor(if(isDark)"#FF453A"else"#FF3B30")
    @Volatile private var presentedRecords:List<JSONObject> = emptyList()
    private var resultCards:LinearLayout?=null
    override fun onConfigurationChanged(newConfig:Configuration){super.onConfigurationChanged(newConfig);render()}
    private fun dp(n:Int)=(n*resources.displayMetrics.density).toInt()
    private fun text(value:String,size:Float=16f)=TextView(this).apply {
        text=value;textSize=size;setTextColor(inkColor);setPadding(0,dp(3),0,dp(3))
        setLineSpacing(dp(3).toFloat(),1f);includeFontPadding=false
    }
    private fun secondary(value:String,size:Float=13f)=text(value,size).apply{setTextColor(secondaryColor)}
    private fun column()=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL}
    private fun row()=LinearLayout(this).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL}
    private fun rounded(fill:Int,radius:Int=24,stroke:Int?=null)=GradientDrawable().apply {
        shape=GradientDrawable.RECTANGLE;setColor(fill);cornerRadius=dp(radius).toFloat()
        stroke?.let{setStroke(dp(1),it)}
    }
    private fun ripple(fill:Int,radius:Int=24,stroke:Int?=null)=RippleDrawable(
        ColorStateList.valueOf(if(isDark)0x26FFFFFF else 0x1A007AFF),rounded(fill,radius,stroke),null)
    private fun gap(parent:LinearLayout,height:Int=12){parent.addView(View(this),LinearLayout.LayoutParams(1,dp(height)))}
    private fun card()=column().apply{background=rounded(surfaceColor);setPadding(dp(18),dp(16),dp(18),dp(16))}
    private fun title(value:String,size:Float=18f)=text(value,size).apply{typeface=Typeface.create("sans-serif-medium",Typeface.NORMAL)}
    private fun badge(value:String,color:Int=blue)=text(value,11f).apply {
        setTextColor(color);background=rounded((color and 0x00FFFFFF) or if(isDark)0x2B000000 else 0x12000000,8)
        setPadding(dp(8),dp(5),dp(8),dp(5));gravity=Gravity.CENTER;setSingleLine()
    }
    private fun icon(resource:Int,color:Int=blue,size:Int=22)=ImageView(this).apply {
        setImageResource(resource);imageTintList=ColorStateList.valueOf(color)
        layoutParams=LinearLayout.LayoutParams(dp(size),dp(size));importantForAccessibility=View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }
    private fun actionButton(label:String,primary:Boolean=false,danger:Boolean=false,iconRes:Int?=null,action:()->Unit)=object:Button(this){
        override fun setEnabled(enabled:Boolean){super.setEnabled(enabled);alpha=if(enabled)1f else 0.45f}
    }.apply {
        text=label;textSize=15f;isAllCaps=false;typeface=Typeface.create("sans-serif-medium",Typeface.NORMAL)
        gravity=Gravity.CENTER;minHeight=dp(50);minimumHeight=dp(50);minimumWidth=0
        setPadding(dp(12),dp(10),dp(12),dp(10));stateListAnimator=null
        val normalText=if(primary)Color.WHITE else if(danger)red else blue
        val fill=if(primary)blue else if(danger)((red and 0x00FFFFFF) or 0x10000000)else groupedColor
        setTextColor(ColorStateList(arrayOf(intArrayOf(-android.R.attr.state_enabled),intArrayOf()),intArrayOf(secondaryColor,normalText)))
        background=RippleDrawable(ColorStateList.valueOf(0x28FFFFFF),rounded(fill,14),null)
        iconRes?.let{setCompoundDrawablesWithIntrinsicBounds(it,0,0,0);compoundDrawableTintList=ColorStateList.valueOf(normalText);compoundDrawablePadding=dp(6)}
        setOnClickListener{performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK);action()}
    }
    private fun button(label:String,action:()->Unit)=actionButton(label,action=action)
    private fun addButton(parent:LinearLayout,view:View){parent.addView(view,LinearLayout.LayoutParams(-1,-2))}
    private fun buttonPair(parent:LinearLayout,first:View,second:View){
        val line=row();line.addView(first,LinearLayout.LayoutParams(0,-2,1f).apply{marginEnd=dp(6)})
        line.addView(second,LinearLayout.LayoutParams(0,-2,1f).apply{marginStart=dp(6)});parent.addView(line)
    }
    private fun section(parent:LinearLayout,value:String,note:String?=null){
        gap(parent,20);parent.addView(title(value,18f).apply{setPadding(dp(4),0,0,dp(8))})
        note?.let{parent.addView(secondary(it).apply{setPadding(dp(4),0,dp(4),dp(10))})}
    }
    private fun scroll(child:View)=ScrollView(this).apply{isFillViewport=true;clipToPadding=false;isVerticalScrollBarEnabled=false;addView(child)}
    private fun cappedPage(page:LinearLayout,maxWidth:Int=780){
        val frame=FrameLayout(this)
        frame.addView(scroll(page),FrameLayout.LayoutParams(minOf(resources.displayMetrics.widthPixels,dp(maxWidth)),-1,Gravity.CENTER_HORIZONTAL))
        content.addView(frame,LinearLayout.LayoutParams(-1,-1))
    }
    private fun pageColumn()=column().apply{setPadding(dp(16),dp(6),dp(16),dp(24))}
    private fun render() {
        if(destroyed)return
        window.statusBarColor=canvasColor;window.navigationBarColor=surfaceColor
        window.decorView.systemUiVisibility=if(isDark)0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        root=column().apply{setBackgroundColor(canvasColor)}
        val header=row().apply{setPadding(dp(22),dp(12),dp(22),dp(10))}
        val heading=column();heading.addView(title(when(tab){1->"日志及模型";2->"设置";else->"ASRtest"},30f))
        heading.addView(secondary(when(tab){1->"查看转写、运行指标与模型资料";2->"模型与识别参数";else->"端侧语音识别测试"},13f))
        header.addView(heading,LinearLayout.LayoutParams(0,-2,1f));header.addView(badge("完全离线",green));root.addView(header)
        content=column();root.addView(content,LinearLayout.LayoutParams(-1,0,1f))
        when(tab){0->testPage();1->logsPage();else->settingsPage()}
        val navigation=row().apply{setPadding(dp(8),dp(8),dp(8),dp(9));background=rounded(surfaceColor,0)}
        listOf("测试","日志及模型","设置").forEachIndexed{i,label->
            val item=column().apply{
                gravity=Gravity.CENTER;background=ripple(if(tab==i)groupedColor else surfaceColor,18)
                setPadding(dp(4),dp(7),dp(4),dp(7));minimumHeight=dp(64);isClickable=true;isFocusable=true;contentDescription=label
                setOnClickListener{performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK);tab=i;render()}
            }
            item.addView(icon(listOf(R.drawable.ic_test,R.drawable.ic_logs,R.drawable.ic_settings)[i],if(tab==i)blue else secondaryColor,23))
            item.addView(text(label,11f).apply{gravity=Gravity.CENTER;setTextColor(if(tab==i)blue else secondaryColor);setPadding(0,dp(5),0,0)})
            navigation.addView(item,LinearLayout.LayoutParams(0,-2,1f).apply{marginStart=dp(4);marginEnd=dp(4)})
        }
        root.addView(View(this).apply{setBackgroundColor(separatorColor)},LinearLayout.LayoutParams(-1,dp(1)))
        root.addView(navigation);setContentView(root)
    }
    private fun modelCard()=card().apply{
        val line=row();val bubble=FrameLayout(this@MainActivity).apply{background=rounded((blue and 0x00FFFFFF)or 0x18000000,16)}
        bubble.addView(icon(R.drawable.ic_test,blue,26),FrameLayout.LayoutParams(dp(26),dp(26),Gravity.CENTER))
        line.addView(bubble,LinearLayout.LayoutParams(dp(52),dp(52)).apply{marginEnd=dp(12)})
        val labels=column();labels.addView(secondary("当前模型",11f));labels.addView(title(selected.title,17f));labels.addView(secondary(selected.framework,12f))
        line.addView(labels,LinearLayout.LayoutParams(0,-2,1f));line.addView(icon(R.drawable.ic_chevron,secondaryColor,18));addView(line)
        isEnabled=!busy;isClickable=true;isFocusable=true;background=ripple(surfaceColor,24)
        contentDescription="选择模型：${selected.title}";setOnClickListener{if(!busy)chooseModel()}
    }
    private fun resultPanel()=card().apply{
        val line=row();line.addView(title("识别结果",18f),LinearLayout.LayoutParams(0,-2,1f))
        line.addView(badge(if(compareMode)"${comparison.size}组对比"else if(selected.streaming)"流式"else"最终转写"));addView(line)
        gap(this,8)
        statusView=secondary(status,13f).apply{setTextColor(blue);setTextIsSelectable(true)};addView(statusView)
        gap(this,8)
        transcriptView=text(transcript,18f).apply{
            setTextIsSelectable(true);minHeight=dp(82);maxLines=6;ellipsize=TextUtils.TruncateAt.END
            setLineSpacing(dp(5).toFloat(),1f);setPadding(0,dp(4),0,dp(4))
            contentDescription="实时及当前转写文字"
        };addView(transcriptView)
        addView(secondary("最终文字与运行指标保存在本轮记录中",11f))
    }
    private fun recordingPanel()=card().apply{
        val mode=row();mode.addView(title("录音测试",18f),LinearLayout.LayoutParams(0,-2,1f));mode.addView(badge("内建麦克风",secondaryColor));addView(mode)
        gap(this,8)
        val toggle=Switch(this@MainActivity).apply{
            text="多模型对比";textSize=15f;setTextColor(inkColor);isChecked=compareMode;isEnabled=!busy
            thumbTintList=ColorStateList(arrayOf(intArrayOf(android.R.attr.state_checked),intArrayOf()),intArrayOf(blue,secondaryColor))
            setOnCheckedChangeListener{_,value->compareMode=value;render()}
        };addView(toggle,LinearLayout.LayoutParams(-1,dp(44)))
        addView(secondary(if(compareMode)"录制同一句话，${comparison.size}组模型依次识别"else if(selected.streaming)"录音时显示实时文字，停止后输出最终结果"else"停止录音后，模型输出完整转写",13f))
        gap(this,12)
        buttonPair(this,
            actionButton("开始录音",primary=true,iconRes=R.drawable.ic_mic){startMicrophone()}.apply{isEnabled=!busy},
            actionButton("停止",danger=true,iconRes=R.drawable.ic_stop){if(recording)stopRecording()else cancelTask()}.apply{isEnabled=busy})
        gap(this,10);addButton(this,button("同一段录音再测一轮"){lastRecording?.let{file->runFiles(listOf(file),comparisonModels(),"comparison",lastRecordingCorpus?.let{mapOf(file.name to it)}?:emptyMap())}?:toast("请先录制一段音频")}.apply{isEnabled=!busy})
    }
    private fun testPage() {
        val controls=pageColumn();val result=pageColumn()
        val model=modelCard();val live=resultPanel();val recordingCard=recordingPanel()
        resultCards=column();renderResultCards()
        if(resources.configuration.screenWidthDp>=700){
            controls.addView(model);gap(controls);controls.addView(recordingCard)
            result.addView(live);result.addView(resultCards)
        }else{
            controls.addView(model);gap(controls);controls.addView(live);gap(controls);controls.addView(recordingCard);controls.addView(resultCards)
        }
        section(controls,"参考文字","填写准确原文后，自动计算CER/WER")
        val truth=card()
        val edit=EditText(this).apply{
            hint="输入这段录音的参考文字";setText(reference);textSize=15f;setTextColor(inkColor);setHintTextColor(secondaryColor)
            minLines=2;gravity=Gravity.TOP;isEnabled=!busy;background=rounded(groupedColor,14);setPadding(dp(12),dp(12),dp(12),dp(12))
        }
        edit.addTextChangedListener(object:android.text.TextWatcher{
            override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){}
            override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){reference=s?.toString()?:""}
            override fun afterTextChanged(s:android.text.Editable?){}
        });truth.addView(edit);controls.addView(truth)
        section(controls,"批量音频")
        val batch=card();batch.addView(title("WAV文件测试",17f));batch.addView(secondary("已选${imported.size}个文件·逐个识别",13f));gap(batch,12)
        buttonPair(batch,actionButton("选择WAV",iconRes=R.drawable.ic_file){pickWav()}.apply{isEnabled=!busy},
            actionButton("开始本轮",primary=true){if(imported.isEmpty())toast("先选择WAV")else runFiles(imported.toList(),comparisonModels(),"batch",emptyMap())}.apply{isEnabled=!busy})
        gap(batch,8);batch.addView(secondary("保留同一批文件，可切换模型再测一轮",12f));controls.addView(batch)
        section(controls,"自动评测")
        val demo=card();demo.addView(title("演示音频对比",17f));demo.addView(secondary("合成测试句·${comparisonModels().size}组模型·每句3轮",13f));gap(demo,12)
        addButton(demo,actionButton("运行演示评测",iconRes=R.drawable.ic_play){runDemo(comparisonModels(),3)}.apply{isEnabled=!busy})
        gap(demo,8);demo.addView(secondary("内存与RTF来自当前设备。演示音频用于检查运行表现，准确率结论请使用真实录音。",12f));controls.addView(demo)
        if(resources.configuration.screenWidthDp>=700){
            val split=row();split.gravity=Gravity.TOP
            split.addView(scroll(controls),LinearLayout.LayoutParams(0,-1,0.44f));split.addView(scroll(result),LinearLayout.LayoutParams(0,-1,0.56f))
            content.addView(split,LinearLayout.LayoutParams(-1,-1))
        }else{
            cappedPage(controls)
        }
    }
    private fun clearPresentedRecords(){presentedRecords=emptyList();resultCards?.removeAllViews()}
    private fun presentRecords(records:JSONArray){
        presentedRecords=(0 until records.length()).map{JSONObject(records.getJSONObject(it).toString())}
        runOnUiThread{if(!destroyed && tab==0)renderResultCards()}
    }
    private fun renderResultCards(){
        val container=resultCards?:return;container.removeAllViews()
        if(presentedRecords.isEmpty())return
        section(container,"本轮结果","每项保留完整转写与设备运行指标")
        presentedRecords.forEach{record->container.addView(recordCard(record));gap(container,12)}
    }
    private fun number(value:Double,decimals:Int=2)=if(value.isFinite())String.format(Locale.US,"%.${decimals}f",value)else"—"
    private fun recordCard(record:JSONObject)=card().apply{
        val state=record.optString("status")
        val header=row();header.addView(title(record.optString("modelTitle","未知模型"),16f),LinearLayout.LayoutParams(0,-2,1f))
        header.addView(badge(when(state){"completed"->"完成";"skipped"->"跳过";"stopped"->"停止";else->"失败"},if(state=="completed")green else if(state=="skipped")secondaryColor else red));addView(header)
        addView(secondary("${record.optString("corpusId")}·第${record.optInt("runIndex",1)}轮",11f));gap(this,8)
        addView(text(record.optString("transcript").ifBlank{if(state=="completed")"未识别到文字"else record.optString("error","未完成")},17f).apply{setTextIsSelectable(true)})
        if(state=="completed"){
            gap(this,10)
            val metrics=row();listOf("音频" to "${number(record.optDouble("audioSeconds"))}s","耗时" to "${number(record.optDouble("inferenceMS"),0)}ms","RTF" to number(record.optDouble("rtf"),3)).forEach{(label,value)->
                val cell=column().apply{background=rounded(groupedColor,12);setPadding(dp(10),dp(8),dp(8),dp(8));addView(secondary(label,10f));addView(title(value,15f))}
                metrics.addView(cell,LinearLayout.LayoutParams(0,-2,1f).apply{marginEnd=dp(5)})
            };addView(metrics);gap(this,8)
            val score=record.optJSONObject("score")
            val accuracy=if(score!=null && !score.isNull("errorRate"))"${score.optString("metric")}=${number(score.optDouble("errorRate")*100,1)}%"else"准确率未标注"
            addView(secondary("RSS峰值${number(record.optLong("peakRssKB")/1024.0,1)}MiB·$accuracy",12f))
            if(record.optString("reference").isNotBlank())addView(secondary("参考：${record.optString("reference")}",12f).apply{setTextIsSelectable(true)})
            if(record.optBoolean("isSynthetic"))addView(secondary("合成演示音频",11f))
        }
        if(record.optString("languageScope").isNotBlank())addView(secondary(record.optString("languageScope"),12f))
    }
    private fun logsPage() {
        val page=pageColumn();val groups=store.groups().take(100)
        val actions=card();actions.addView(title("测试记录",18f));actions.addView(secondary("${groups.size}组记录·JSON与JSONL过程日志",13f));gap(actions,12)
        buttonPair(actions,actionButton("导出全部ZIP",primary=true){exportLogs()}.apply{isEnabled=!busy},
            actionButton("清空日志",danger=true){AlertDialog.Builder(this@MainActivity).setTitle("清空全部日志？").setMessage("将删除结果JSON和过程JSONL。录音及模型单独保存。")
                .setPositiveButton("清空"){_,_->worker.execute{store.clear();runOnUiThread{render()}}}.setNegativeButton("取消",null).show()}.apply{isEnabled=!busy})
        page.addView(actions)
        section(page,"历史测试")
        if(groups.isEmpty()){
            page.addView(card().apply{addView(title("还没有测试记录",17f));addView(secondary("完成一次录音或批量测试后，结果会保存在这里。",14f))})
        }
        groups.forEach{group->
            val records=group.optJSONArray("records")?:JSONArray()
            val groupCard=card();val heading=row()
            val kind=when(group.optString("kind")){"comparison"->"录音对比";"microphone"->"单模型录音";"batch"->"批量音频";"demo-benchmark","benchmark"->"自动评测";else->"测试记录"}
            heading.addView(title(kind,17f),LinearLayout.LayoutParams(0,-2,1f));heading.addView(badge(when(group.optString("status")){"completed"->"已完成";"stopped"->"已停止";"failed"->"失败";else->"处理中"}));heading.addView(icon(R.drawable.ic_chevron,secondaryColor,17));groupCard.addView(heading)
            groupCard.addView(secondary("${SimpleDateFormat("MM月dd日HH:mm",Locale.CHINA).format(Date(group.optLong("startedAt")))}·${records.length()}条结果",12f))
            val names=(0 until records.length()).map{records.optJSONObject(it)?.optString("modelTitle")?:""}.filter{it.isNotBlank()}.distinct()
            groupCard.addView(secondary(names.joinToString("、").ifBlank{"暂无完成记录"},13f))
            groupCard.background=ripple(surfaceColor,24);groupCard.isClickable=true;groupCard.isFocusable=true;groupCard.setOnClickListener{showGroup(group)}
            page.addView(groupCard);gap(page,12)
        }
        section(page,"内置模型","八组模型随APK集成，全部在设备本地识别")
        ModelSpec.all.forEach{model->
            page.addView(card().apply{
                val header=row();header.addView(title(model.title,17f),LinearLayout.LayoutParams(0,-2,1f));header.addView(badge(if(model.streaming)"流式"else"非流式"));addView(header)
                addView(secondary("${model.framework}·${model.languages}",13f));gap(this,5)
                addView(secondary("官方参数：${model.parameters?.let{"${number(it/1000000.0,0)}M"}?:"未披露"}",12f))
                addView(text(model.repo,12f).apply{setTextColor(blue);setTextIsSelectable(true);autoLinkMask=android.text.util.Linkify.WEB_URLS})
            });gap(page,12)
        };cappedPage(page)
    }
    private fun showGroup(group:JSONObject) {
        val records=group.optJSONArray("records")?:JSONArray()
        val msg=StringBuilder()
        for(i in 0 until records.length()) { val r=records.getJSONObject(i);msg.append("${r.optString("modelTitle")}·${r.optString("corpusId")}·第${r.optInt("runIndex",1)}轮\n${r.optString("status")}｜${r.optDouble("audioSeconds")}秒｜${r.optDouble("inferenceMS")}ms｜RTF=${r.opt("rtf")}\n${r.optString("transcript")}\n${r.optString("error")}\n\n") }
        val view=scroll(text(msg.toString(),15f).apply{setTextIsSelectable(true);setPadding(dp(12),0,dp(12),0)})
        AlertDialog.Builder(this).setTitle("完整测试记录").setView(view).setPositiveButton("关闭",null)
            .setNeutralButton("删除本组"){_,_->if(!busy)AlertDialog.Builder(this).setTitle("删除本组日志？").setPositiveButton("删除"){_,_->worker.execute{store.delete(group.getString("id"));runOnUiThread{render()}}}.setNegativeButton("取消",null).show()}.show()
    }
    private fun settingRow(label:String,value:String,action:()->Unit)=row().apply{
        minimumHeight=dp(52);background=ripple(surfaceColor,12);setPadding(dp(4),dp(7),dp(4),dp(7))
        addView(text(label,15f),LinearLayout.LayoutParams(0,-2,1f))
        addView(text(value,14f).apply{setTextColor(blue);setPadding(dp(8),0,dp(6),0)});addView(icon(R.drawable.ic_chevron,secondaryColor,16))
        isEnabled=!busy;isClickable=true;isFocusable=true;setOnClickListener{if(!busy)action()}
    }
    private fun settingsPage() {
        val page=pageColumn()
        section(page,"模型选择")
        page.addView(modelCard());gap(page,12)
        val comparisonCard=card();comparisonCard.addView(title("对比模型",18f));comparisonCard.addView(secondary("录制同一句话，在所选模型间依次测试",12f));gap(comparisonCard,8)
        ModelSpec.all.forEach{model->comparisonCard.addView(CheckBox(this).apply{
            text=model.title;textSize=14f;setTextColor(inkColor);isChecked=model.id in comparison;isEnabled=!busy
            buttonTintList=ColorStateList.valueOf(blue);minHeight=dp(45);setPadding(0,dp(3),0,dp(3))
            setOnCheckedChangeListener{_,checked->if(checked)comparison.add(model.id)else comparison.remove(model.id)}
        })};page.addView(comparisonCard)
        section(page,"识别设置")
        val options=card();val languageCodes=listOf("auto","zh","en","ja","yue","ko");val languageNames=listOf("自动识别","中文","英文","日文","粤语","韩文")
        options.addView(settingRow("语言提示",languageNames[languageCodes.indexOf(language).coerceAtLeast(0)]){
            AlertDialog.Builder(this).setTitle("语言提示").setSingleChoiceItems(languageNames.toTypedArray(),languageCodes.indexOf(language).coerceAtLeast(0)){dialog,index->language=languageCodes[index];getPreferences(0).edit().putString("language",language).apply();dialog.dismiss();render()}.setNegativeButton("取消",null).show()
        })
        options.addView(View(this).apply{setBackgroundColor(separatorColor)},LinearLayout.LayoutParams(-1,dp(1)))
        options.addView(settingRow("推理线程","${threads}线程"){
            AlertDialog.Builder(this).setTitle("推理线程").setSingleChoiceItems(arrayOf("1线程","2线程","3线程","4线程"),threads-1){dialog,index->threads=index+1;getPreferences(0).edit().putInt("threads",threads).apply();dialog.dismiss();render()}.setNegativeButton("取消",null).show()
        })
        options.addView(secondary("Vosk线程由运行库管理；语言提示须与模型支持范围一致。",12f));gap(options,8)
        options.addView(Switch(this).apply{
            text="SenseVoice的ITN";textSize=15f;setTextColor(inkColor);isChecked=itn;isEnabled=!busy
            thumbTintList=ColorStateList.valueOf(blue);setOnCheckedChangeListener{_,checked->itn=checked}
        });options.addView(secondary("逆文本归一化，用于规范数字等表达。",12f));page.addView(options)
        section(page,"音频输入")
        page.addView(card().apply{
            addView(title("手机内建麦克风",17f));addView(secondary("16kHz·单声道",13f));gap(this,6)
            addView(secondary("多模型对比最长30秒。单模型流式最长600秒，非流式遵循各模型输入限制。",13f))
        })
        section(page,"关于ASRtest")
        page.addView(card().apply{
            val heading=row();heading.addView(title("ASRtest",20f),LinearLayout.LayoutParams(0,-2,1f));heading.addView(badge(BuildConfig.VERSION_NAME,secondaryColor));addView(heading)
            addView(secondary("全部识别在本地运行，模型随APK集成。",13f));gap(this,8)
            addView(secondary("内存记录本进程RSS，每100ms采样；模型加载耗时单独记录。RTF使用实际识别耗时除以音频时长。",12f))
            addView(secondary("FLOPs/MIPS需独立统计，不从耗时反推。",12f))
        });cappedPage(page)
    }
    private fun chooseModel(){
        if(busy)return
        val labels=ModelSpec.all.map{"${it.title}\n${it.framework}·${if(it.streaming)"流式"else"非流式"}"}.toTypedArray()
        AlertDialog.Builder(this).setTitle("选择识别模型").setSingleChoiceItems(labels,ModelSpec.all.indexOf(selected)){dialog,index->
            selected=ModelSpec.all[index];getPreferences(0).edit().putString("model",selected.id).apply();dialog.dismiss();render()
        }.setNegativeButton("取消",null).show()
    }
    private fun comparisonModels()=if(compareMode)ModelSpec.all.filter{it.id in comparison}else listOf(selected)
    private fun toast(message:String)=Toast.makeText(this,message,Toast.LENGTH_LONG).show()
    private fun update(message:String,text:String?=null) { status=message;if(text!=null)transcript=text;runOnUiThread{if(!destroyed && tab==0){statusView.text=status;transcriptView.text=transcript}} }
    private fun task(block:()->Unit) {
        if(busy){toast("请等待当前任务结束");return};busy=true;stop.set(false);recordStop.set(false);clearPresentedRecords();render()
        worker.execute {
            val lock=(getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"ASRtest:bench")
            lock.acquire(60*60*1000L)
            try {block()} catch(t:Throwable){update("任务失败：${t.message}")} finally {activeEngine.set(null);if(lock.isHeld)lock.release();busy=false;recording=false;runOnUiThread{if(!destroyed){render();val pending=pendingBenchmark;pendingBenchmark=null;if(pending!=null)startBenchmark(pending)}}}
        }
    }
    private fun cancelTask(){stop.set(true);activeEngine.get()?.cancel();update("正在停止，保留已完成记录")}
    private fun stopRecording(){recordStop.set(true);update("正在结束录音")}
    private fun startMicrophone() {
        if(busy)return
        if(checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED){requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO),100);return}
        val chosen=comparisonModels();if(chosen.isEmpty()){toast("先选择至少一个模型");return}
        val comparative=compareMode;val options=Options(threads,language,itn);val truth=reference
        task {
            val group=newGroup(if(comparative)"comparison"else"microphone");store.save(group)
            var engine:AsrEngine?=null;var sampler:MemorySampler?=null;var mic:AudioRecord?=null
            var loadMS=0.0;var compute=0L
            try {
                if(!comparative) {
                    val p=models.ensure(chosen.first()){update(it)}
                    if(stop.get())throw java.util.concurrent.CancellationException("用户主动停止")
                    val start=System.nanoTime();engine=EngineFactory.create(chosen.first(),p,options.threads,options.language,options.itn)
                    loadMS=(System.nanoTime()-start)/1e6;activeEngine.set(engine);sampler=MemorySampler().apply{start()}
                }
                if(stop.get())throw java.util.concurrent.CancellationException("用户主动停止")
                val minimum=AudioRecord.getMinBufferSize(16000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT)
                require(minimum>0){"设备不支持16kHz麦克风输入"}
                mic=AudioRecord(MediaRecorder.AudioSource.MIC,16000,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT,maxOf(minimum*2,6400))
                require(mic.state==AudioRecord.STATE_INITIALIZED){"无法初始化手机麦克风"}
                val pcm=ArrayList<FloatArray>();var sampleCount=0;val limit=if(comparative)30 else chosen.first().maxSeconds
                recording=true;mic.startRecording();update("录音中·最多${limit}秒","")
                val short=ShortArray(1600)
                while(!recordStop.get() && !stop.get() && sampleCount<limit*16000) {
                    val count=mic.read(short,0,minOf(short.size,limit*16000-sampleCount));if(count<=0)throw IllegalStateException("麦克风读取失败：$count")
                    val chunk=FloatArray(count){short[it]/32768f};pcm.add(chunk);sampleCount+=count
                    if(engine!=null) {
                        val begin=System.nanoTime();val partial=engine.accept(chunk);compute+=System.nanoTime()-begin
                        if(partial.isNotBlank()){update("录音中·${"%.1f".format(sampleCount/16000.0)}秒",partial);store.appendEvent(group.getString("id"),JSONObject().put("type","partial").put("text",partial).put("audioSeconds",sampleCount/16000.0))}
                    }
                }
                mic.stop();mic.release();mic=null;recording=false
                if(stop.get())throw java.util.concurrent.CancellationException("用户主动停止")
                val audio=FloatArray(sampleCount);var offset=0;pcm.forEach{it.copyInto(audio,offset);offset+=it.size};pcm.clear()
                val file=File(filesDir,"recordings/${UUID.randomUUID()}.wav");WavIO.write(file,audio);lastRecording=file
                lastRecordingCorpus=Corpus(file.name,truth,options.language,false)
                if(comparative)runFilesInternal(listOf(file),chosen,group,mapOf(file.name to Corpus(file.name,truth,options.language,false)),1,options)
                else {
                    val begin=System.nanoTime();val final=engine!!.finish();compute+=System.nanoTime()-begin;sampler!!.stop()
                    if(stop.get())throw java.util.concurrent.CancellationException("用户主动停止")
                    val result=record(chosen.first(),file.name,audio.size/16000.0,loadMS,compute/1e6,sampler,final,truth,options.language,false,1,options)
                    group.getJSONArray("records").put(result);presentRecords(group.getJSONArray("records"));store.save(group);update("单次测试完成",final)
                }
            } catch(t:Throwable){group.put("error",t.message);group.put("status",if(stop.get())"stopped"else"failed");throw t}
            finally {
                recording=false;mic?.let{runCatching{it.stop()};it.release()};sampler?.stop();activeEngine.set(null);engine?.close()
                if(group.optString("status")=="running")closeGroup(group,null)
                else{group.put("endedAt",System.currentTimeMillis());store.save(group)}
            }
        }
    }
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<out String>,grantResults:IntArray){super.onRequestPermissionsResult(requestCode,permissions,grantResults);if(requestCode==100 && grantResults.firstOrNull()==PackageManager.PERMISSION_GRANTED)startMicrophone()}
    private fun pickWav(){startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply{type="audio/*";putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);addCategory(Intent.CATEGORY_OPENABLE)},200)}
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode!=200 || resultCode!=RESULT_OK || data==null)return
        val uris=if(data.clipData!=null)(0 until data.clipData!!.itemCount).map{data.clipData!!.getItemAt(it).uri}else listOfNotNull(data.data)
        if(uris.size>100){toast("每批最多100个文件");return}
        task {
            imported.forEach{it.delete()};imported.clear();importedNames.clear()
            for((i,uri) in uris.withIndex()) {
                val file=File(cacheDir,"batch-${UUID.randomUUID()}.wav")
                try {
                    val originalName=contentResolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use{cursor->if(cursor.moveToFirst())cursor.getString(0)else null}?:uri.lastPathSegment?:"音频${i+1}.wav"
                    contentResolver.openInputStream(uri)!!.use{input->file.outputStream().use{input.copyTo(it)}};imported.add(file);importedNames[file.name]=originalName
                }catch(e:Exception){file.delete();update("导入第${i+1}个文件失败：${e.message}")}
            };update("已暂存${imported.size}个WAV，可切换模型重测")
        }
    }
    private data class Corpus(val id:String,val reference:String,val language:String,val synthetic:Boolean)
    private data class Options(val threads:Int,val language:String,val itn:Boolean)
    private fun demo():Pair<List<File>,Map<String,Corpus>> {
        val list=JSONArray(assets.open("evaluation/demo/corpus.json").bufferedReader().use{it.readText()})
        val folder=File(filesDir,"demo").apply{mkdirs()};val files=ArrayList<File>();val refs=HashMap<String,Corpus>()
        for(i in 0 until list.length()) {val v=list.getJSONObject(i);val name=v.getString("file");val f=File(folder,name)
            if(!f.exists())assets.open("evaluation/demo/$name").use{input->f.outputStream().use{input.copyTo(it)}}
            files.add(f);refs[name]=Corpus(v.getString("id"),v.getString("reference"),v.getString("language"),true)
        };return files to refs
    }
    private fun runDemo(selected:List<ModelSpec>,runs:Int){if(selected.isEmpty()){toast("先选择模型");return};val options=Options(threads,language,itn);task{val (files,truth)=demo();val group=newGroup("demo-benchmark");runFilesInternal(files,selected,group,truth,runs,options);closeGroup(group,null)}}
    private fun startBenchmark(value:Intent) {
        if(busy){pendingBenchmark=value;return}
        val id=value.getStringExtra("benchModel")?:return;val spec=runCatching{ModelSpec.get(id)}.getOrNull()?:return
        val options=Options(value.getIntExtra("benchThreads",2).coerceIn(1,4),"auto",true)
        val runs=value.getIntExtra("benchRuns",3).coerceIn(1,10);val corpus=value.getStringExtra("benchCorpus")?:"all"
        tab=0;selected=spec;compareMode=false;task {
            val (all,truth)=demo();val files=if(corpus=="all")all else all.filter{truth[it.name]?.id==corpus}
            val group=newGroup("benchmark").put("modelId",id).put("threads",options.threads)
            store.save(group,id)
            try {runFilesInternal(files,listOf(spec),group,truth,runs,options,id);closeGroup(group,id)}
            catch(t:Throwable){group.put("error",t.message);closeGroup(group,id);throw t}
        }
    }
    private fun runFiles(files:List<File>,selected:List<ModelSpec>,kind:String,truth:Map<String,Corpus>) {
        if(selected.isEmpty()){toast("先选择至少一个模型");return};val options=Options(threads,language,itn)
        task{val group=newGroup(kind);runFilesInternal(files,selected,group,truth,1,options);closeGroup(group,null)}
    }
    private fun runFilesInternal(files:List<File>,selected:List<ModelSpec>,group:JSONObject,truth:Map<String,Corpus>,runs:Int,options:Options,marker:String?=null) {
        store.save(group,marker);val total=files.size*selected.size*runs;var done=0
        outer@for(model in selected)for(file in files)for(run in 1..runs) {
            if(stop.get())break@outer
            val info=truth[file.name]?:Corpus(importedNames[file.name]?:file.name,"",options.language,false)
            if((model.id=="voskChinese" && info.language=="en") || (model.id=="voskEnglish" && info.language=="zh")) {
                group.getJSONArray("records").put(JSONObject().put("id",UUID.randomUUID().toString()).put("modelId",model.id).put("modelTitle",model.title).put("corpusId",info.id).put("runIndex",run).put("status","skipped").put("error","对应单语模型不支持本音频语言"));presentRecords(group.getJSONArray("records"));store.save(group,marker);done++;continue
            }
            update("${++done}/$total·${model.title}·${info.id}·第${run}轮","")
            var engine:AsrEngine?=null;var sampler:MemorySampler?=null
            try {
                val audio=WavIO.read(file,model.maxSeconds)
                val root=models.ensure(model){update(it)};if(stop.get())break@outer
                val begin=System.nanoTime();engine=EngineFactory.create(model,root,options.threads,options.language,options.itn)
                val loadMS=(System.nanoTime()-begin)/1e6;activeEngine.set(engine)
                sampler=MemorySampler().apply{start()};var compute=0L;var partial=""
                var offset=0
                while(offset<audio.size) {
                    if(stop.get())throw java.util.concurrent.CancellationException("用户主动停止")
                    val end=minOf(offset+1600,audio.size);val chunk=audio.copyOfRange(offset,end);val t=System.nanoTime()
                    val value=engine.accept(chunk);compute+=System.nanoTime()-t
                    if(value!=partial && value.isNotBlank()){partial=value;store.appendEvent(group.getString("id"),JSONObject().put("type","partial").put("modelId",model.id).put("corpusId",info.id).put("runIndex",run).put("text",value));update("${done}/$total·${model.title}·流式中间结果",value)}
                    offset=end
                }
                val endBegin=System.nanoTime();val final=engine.finish();compute+=System.nanoTime()-endBegin;sampler.stop()
                if(stop.get())throw java.util.concurrent.CancellationException("用户主动停止")
                val result=record(model,info.id,audio.size/16000.0,loadMS,compute/1e6,sampler,final,info.reference,info.language,info.synthetic,run,options)
                if(info.language=="mixed" && model.id.startsWith("vosk"))result.put("languageScope","单语模型不覆盖完整中英混说")
                group.getJSONArray("records").put(result);presentRecords(group.getJSONArray("records"));store.appendEvent(group.getString("id"),JSONObject().put("type","final").put("recordId",result.getString("id")).put("text",final))
                update("${done}/$total·已完成",final)
            } catch(t:Throwable) {
                val result=JSONObject().put("id",UUID.randomUUID().toString()).put("modelId",model.id).put("modelTitle",model.title).put("corpusId",info.id)
                    .put("runIndex",run).put("status",if(stop.get())"stopped"else"failed").put("error",t.message?:t.javaClass.name)
                group.getJSONArray("records").put(result);presentRecords(group.getJSONArray("records"))
                update("文件处理失败，继续下一项",result.getString("error"))
            } finally {sampler?.stop();activeEngine.set(null);engine?.close();store.save(group,marker)}
        }
    }
    private fun newGroup(kind:String)=JSONObject().put("schemaVersion",1).put("id",UUID.randomUUID().toString()).put("kind",kind).put("status","running").put("startedAt",System.currentTimeMillis()).put("records",JSONArray())
    private fun closeGroup(group:JSONObject,marker:String?) {group.put("endedAt",System.currentTimeMillis()).put("status",if(stop.get())"stopped"else if(group.has("error"))"failed"else"completed");store.save(group,marker);update(if(stop.get())"任务已停止"else if(group.has("error"))"本轮失败，已保留记录"else"本轮完成，结果已保存")}
    private fun record(model:ModelSpec,corpusId:String,seconds:Double,loadMS:Double,inferenceMS:Double,memory:MemorySampler?,final:String,reference:String,lang:String,synthetic:Boolean,run:Int,options:Options):JSONObject {
        val r=JSONObject().put("id",UUID.randomUUID().toString()).put("modelId",model.id).put("modelTitle",model.title).put("framework",model.framework).put("streaming",model.streaming)
            .put("corpusId",corpusId).put("reference",reference).put("language",lang).put("isSynthetic",synthetic).put("transcript",final).put("audioSeconds",seconds)
            .put("modelLoadMS",loadMS).put("inferenceMS",inferenceMS).put("rtf",if(seconds>0)inferenceMS/1000/seconds else JSONObject.NULL)
            .put("baselineRssKB",memory?.baselineRssKB?:0).put("peakRssKB",memory?.peakRssKB?:0).put("endPssKB",MemorySampler.pss())
            .put("memoryDefinition","本进程VmRSS，100ms采样；baseline在加载后；peak覆盖音频接收与完成推理；PSS仅结束快照")
            .put("timingDefinition","累计accept和finish调用；含框架内部特征提取、解码和Nano VAD，不含模型加载、WAV读取、UI等待和日志写入")
            .put("threadsRequested",options.threads).put("effectiveThreads",if(model.id.startsWith("vosk"))"runtime default"else options.threads)
            .put("languageHint",options.language).put("useITN",options.itn).put("runIndex",run).put("status","completed").put("device",MemorySampler.device())
            .put("parameterCount",model.parameters?:JSONObject.NULL).put("parameterSource","官方模型标称；非运行时测量").put("flops",JSONObject.NULL).put("flopsNote","未测，不能由RTF或CPU利用率推算")
        if(reference.isNotBlank())r.put("score",Metrics.evaluate(reference,final,lang))
        return r
    }
    private fun formatRecord(r:JSONObject):String {
        val score=r.optJSONObject("score");val error=if(score!=null && !score.isNull("errorRate"))"｜${score.optString("metric")}=${"%.1f".format(score.getDouble("errorRate")*100)}%"else""
        return "${r.optString("modelTitle")}·${r.optString("corpusId")}·第${r.optInt("runIndex")}轮\n${r.optString("transcript")}\n${"%.2f".format(r.optDouble("audioSeconds"))}秒｜${"%.0f".format(r.optDouble("inferenceMS"))}ms｜RTF=${"%.3f".format(r.optDouble("rtf"))}$error\nRSS峰值=${"%.1f".format(r.optLong("peakRssKB")/1024.0)}MiB"
    }
    private fun exportLogs() {if(busy)return;worker.execute{try{store.export();runOnUiThread{val uri=Uri.parse("content://com.roylyl.asrtest.logs/ASRtest-logs.zip");startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply{type="application/zip";putExtra(Intent.EXTRA_STREAM,uri);addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)},"导出测试日志"))}}catch(e:Exception){runOnUiThread{toast("导出失败：${e.message}")}}}}
}
