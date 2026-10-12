package com.roylyl.asrtest

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

class LogProvider:ContentProvider() {
    override fun onCreate()=true
    private fun file(uri:Uri):File {
        require(uri.path=="/ASRtest-logs.zip")
        return File(requireNotNull(context).cacheDir,"ASRtest-logs.zip")
    }
    override fun openFile(uri:Uri,mode:String):ParcelFileDescriptor { require(mode=="r");return ParcelFileDescriptor.open(file(uri),ParcelFileDescriptor.MODE_READ_ONLY) }
    override fun getType(uri:Uri)="application/zip"
    override fun query(uri:Uri,projection:Array<out String>?,selection:String?,selectionArgs:Array<out String>?,sortOrder:String?):Cursor = MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME,OpenableColumns.SIZE)).apply{addRow(arrayOf<Any>("ASRtest-logs.zip",file(uri).length()))}
    override fun insert(uri:Uri,values:ContentValues?):Uri?=throw UnsupportedOperationException()
    override fun delete(uri:Uri,selection:String?,selectionArgs:Array<out String>?):Int=throw UnsupportedOperationException()
    override fun update(uri:Uri,values:ContentValues?,selection:String?,selectionArgs:Array<out String>?):Int=throw UnsupportedOperationException()
}
