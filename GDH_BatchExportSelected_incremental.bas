'====================================================================
' 批次匯出「市場清單」裡打勾的商品(C欄) × 打勾的週期(D欄)，
' 每個組合都匯出一份CSV到 D:\資料查詢\ExportCSV\
'
' 用法：
'   1. 「市場清單」A欄旁的C欄，想匯出的商品打 X
'   2. 「市場清單」B欄旁的D欄，想匯出的週期打 X
'   3. 執行本巨集(建議做成按鈕)，會匯出「所有勾選商品」x「所有勾選週期」的全部組合
'   4. 週期清單裡如果勾選「ALL」，會自動展開成 D1/H4/H1/M15 這4個
'      (量化分析引擎目前只支援這4個週期，其餘週期只會單純匯出CSV，不會進優化分析)
'
' ⚠️ 這版本改成支援增量更新：
'   - 匯出前會先讀 D:\資料查詢\ExportCSV\merged\_last_bar_state.csv
'     （由 merge_export_csv.py 每次合併後自動產生），裡面記錄每個
'     商品/週期在資料庫裡目前最新一根K棒的時間。
'   - 該商品/週期「已經有資料」的話，只帶 --since 抓這個時間點之後的
'     新K棒，速度快很多，商品越多、資料庫越大也不會越跑越慢。
'   - 「全新商品/週期」（狀態檔裡查不到）還是走原本 --amount/--unit
'     的整批回補，抓一次完整歷史。
'   - 找不到狀態檔（例如你還沒跑過 merge_export_csv.py）時，全部商品
'     都走整批回補，行為跟舊版一樣，不會出錯。
'====================================================================

Public Sub GDH_BatchExportSelected()
    Dim wsList As Worksheet, wsApp As Worksheet
    Dim lastRow As Long, r As Long
    Dim symbolStr As String, mark As String
    Dim selectedSymbols As Collection
    Dim selectedTFs As Collection
    Set selectedSymbols = New Collection
    Set selectedTFs = New Collection

    On Error Resume Next
    Set wsList = ThisWorkbook.Worksheets("市場清單")
    Set wsApp = ThisWorkbook.Worksheets("DATE")
    On Error GoTo 0

    If wsList Is Nothing Then
        MsgBox "找不到工作表【市場清單】！", vbCritical
        Exit Sub
    End If

    ' 1a. 蒐集所有打勾的商品(A欄+C欄，去除重複)
    Dim seenSym As Object
    Set seenSym = CreateObject("Scripting.Dictionary")
    lastRow = wsList.Cells(wsList.Rows.Count, "A").End(xlUp).Row
    For r = 2 To lastRow
        mark = Trim$(CStr(wsList.Cells(r, 3).value))
        symbolStr = Trim$(CStr(wsList.Cells(r, 1).value))
        If Len(mark) > 0 And Len(symbolStr) > 0 Then
            If Not seenSym.Exists(UCase(symbolStr)) Then
                selectedSymbols.Add symbolStr
                seenSym.Add UCase(symbolStr), True
            End If
        End If
    Next r

    ' 1b. 蒐集所有打勾的週期(B欄+D欄，去除重複；ALL自動展開成D1/H4/H1/M15)
    Dim seenTF As Object
    Set seenTF = CreateObject("Scripting.Dictionary")
    Dim lastRowB As Long
    lastRowB = wsList.Cells(wsList.Rows.Count, "B").End(xlUp).Row
    Dim tfStr As String
    For r = 2 To lastRowB
        mark = Trim$(CStr(wsList.Cells(r, 4).value))
        tfStr = UCase(Trim$(CStr(wsList.Cells(r, 2).value)))
        If Len(mark) > 0 And Len(tfStr) > 0 Then
            If tfStr = "ALL" Then
                Dim expandTF As Variant
                expandTF = Array("D1", "H4", "H1", "M15")
                Dim k As Long
                For k = LBound(expandTF) To UBound(expandTF)
                    If Not seenTF.Exists(expandTF(k)) Then
                        selectedTFs.Add expandTF(k)
                        seenTF.Add expandTF(k), True
                    End If
                Next k
            Else
                If Not seenTF.Exists(tfStr) Then
                    selectedTFs.Add tfStr
                    seenTF.Add tfStr, True
                End If
            End If
        End If
    Next r

    If selectedSymbols.Count = 0 Then
        MsgBox "請先到「市場清單」工作表的C欄，在想匯出的商品旁邊打 X 再執行。", vbExclamation, "尚未選取商品"
        Exit Sub
    End If
    If selectedTFs.Count = 0 Then
        MsgBox "請先到「市場清單」工作表的D欄，在想匯出的週期旁邊打 X 再執行。", vbExclamation, "尚未選取週期"
        Exit Sub
    End If

    Dim totalCombos As Long
    totalCombos = selectedSymbols.Count * selectedTFs.Count

    Dim confirmMsg As String
    confirmMsg = "即將批次匯出：" & vbCrLf & _
                 "商品：" & selectedSymbols.Count & " 個" & vbCrLf & _
                 "週期：" & selectedTFs.Count & " 個" & vbCrLf & _
                 "總共：" & totalCombos & " 份CSV" & vbCrLf & vbCrLf & _
                 "數量較多時會花較長時間，確定要開始嗎？"

    If MsgBox(confirmMsg, vbQuestion + vbYesNo, "確認批次匯出") = vbNo Then Exit Sub

    ' 2. 準備共用參數(沿用DATE工作表F5的天數、H5的單位，跟單一商品匯出一致；
    '    這組值只有在「該商品/週期是全新的、還沒有增量狀態」時才會用到)
    Dim amount As Long, unitText As String, unitCode As String
    amount = CLng(Val(wsApp.Range("F5").Value2))
    If amount < 1 Then amount = 1000

    unitText = Trim$(CStr(wsApp.Range("H5").Value2))
    Select Case unitText
        Case ChrW(&H5929): unitCode = "D"
        Case ChrW(&H6708): unitCode = "M"
        Case ChrW(&H5E74): unitCode = "Y"
        Case Else: unitCode = unitText
    End Select
    If unitCode = "" Then unitCode = "Y"

    Dim folderPath As String
    folderPath = "D:\資料查詢\ExportCSV\"
    If Dir$(folderPath, vbDirectory) = "" Then
        If Dir$("D:\資料查詢", vbDirectory) = "" Then MkDir "D:\資料查詢"
        MkDir folderPath
    End If

    ' ---------- 新增：讀取增量狀態檔（merge_export_csv.py 產生的） ----------
    Dim lastBarDict As Object
    Set lastBarDict = CreateObject("Scripting.Dictionary")
    Dim stateFilePath As String
    stateFilePath = folderPath & "merged\_last_bar_state.csv"
    If Dir$(stateFilePath) <> "" Then
        Dim fnum As Integer, ln As String, isFirst As Boolean, cols() As String
        fnum = FreeFile
        isFirst = True
        Open stateFilePath For Input As #fnum
        Do While Not EOF(fnum)
            Line Input #fnum, ln
            If isFirst Then
                isFirst = False ' 跳過表頭 Symbol,TF,LastDateTime
            Else
                If Len(Trim$(ln)) > 0 Then
                    cols = Split(ln, ",")
                    If UBound(cols) >= 2 Then
                        Dim stateKey As String
                        stateKey = UCase(Trim$(cols(0))) & "|" & UCase(Trim$(cols(1)))
                        If Not lastBarDict.Exists(stateKey) Then
                            lastBarDict.Add stateKey, Trim$(cols(2))
                        End If
                    End If
                End If
            End If
        Loop
        Close #fnum
    End If
    ' 找不到狀態檔（Dir$為空）就讓 lastBarDict 保持空的，
    ' 下面查詢時全部都會落到「全新商品，整批回補」的分支，行為跟舊版一致。

    Dim pythonExe As String, scriptFile As String
    pythonExe = Environ$("LOCALAPPDATA") & "\hermes\hermes-agent\venv\Scripts\python.exe"
    scriptFile = "D:\資料查詢\gordon_mt5_incremental.py"
    If Dir$(scriptFile) = "" Then scriptFile = ThisWorkbook.Path & "\gordon_mt5_incremental.py"

    If Dir$(pythonExe) = "" Then
        MsgBox "找不到 Python 執行檔：" & pythonExe, vbCritical, "環境錯誤"
        Exit Sub
    End If
    If Dir$(scriptFile) = "" Then
        MsgBox "找不到腳本檔案：" & scriptFile, vbCritical, "環境錯誤"
        Exit Sub
    End If

    Dim shell As Object
    Set shell = CreateObject("WScript.Shell")

    Application.ScreenUpdating = False
    Application.DisplayAlerts = False

    Dim successCount As Long, failCount As Long, incrementalCount As Long, fullCount As Long
    Dim failList As String
    successCount = 0
    failCount = 0
    incrementalCount = 0
    fullCount = 0

    Dim s As Variant, t As Variant
    Dim symIdx As Long: symIdx = 0
    Dim doneCombos As Long: doneCombos = 0

    For Each s In selectedSymbols
        symIdx = symIdx + 1
        symbolStr = CStr(s)

        For Each t In selectedTFs
            Dim tfName As String: tfName = CStr(t)
            doneCombos = doneCombos + 1

            ' ---------- 新增：查詢這個 商品/週期 有沒有既有資料，決定增量或整批 ----------
            Dim lookupKey As String
            lookupKey = UCase(symbolStr) & "|" & UCase(tfName)
            Dim isIncremental As Boolean
            Dim sinceValue As String
            isIncremental = lastBarDict.Exists(lookupKey)
            If isIncremental Then sinceValue = CStr(lastBarDict(lookupKey))

            Application.StatusBar = "批次匯出中... (" & doneCombos & "/" & totalCombos & ") " & _
                symbolStr & " - " & tfName & IIf(isIncremental, "（增量）", "（整批回補）")
            DoEvents

            Dim outputCsv As String
            outputCsv = "D:\資料查詢\mt_export_" & tfName & ".csv"

            Dim command As String
            If isIncremental Then
                command = Quote(pythonExe) & " " & Quote(scriptFile) & _
                    " --db " & Quote("D:\資料查詢") & _
                    " --symbol " & Quote(symbolStr) & _
                    " --timeframe " & Quote(tfName) & _
                    " --since " & Quote(sinceValue) & _
                    " --output " & Quote(outputCsv)
                incrementalCount = incrementalCount + 1
            Else
                command = Quote(pythonExe) & " " & Quote(scriptFile) & _
                    " --db " & Quote("D:\資料查詢") & _
                    " --symbol " & Quote(symbolStr) & _
                    " --timeframe " & Quote(tfName) & _
                    " --amount " & CStr(amount) & _
                    " --unit " & unitCode & _
                    " --output " & Quote(outputCsv)
                fullCount = fullCount + 1
            End If

            Dim exitCode As Long
            exitCode = shell.Run(command, 0, True)

            If exitCode = 0 And Dir$(outputCsv) <> "" Then
                Dim exportBook As Workbook
                On Error Resume Next
                Set exportBook = Workbooks.Open(fileName:=outputCsv, ReadOnly:=True)
                On Error GoTo 0

                If Not exportBook Is Nothing Then
                    Dim lastR As Long
                    lastR = exportBook.Worksheets(1).Cells(exportBook.Worksheets(1).Rows.Count, "A").End(xlUp).Row

                    If lastR >= 2 Then
                        Dim wbTarget As Workbook
                        Set wbTarget = Workbooks.Add(xlWBATWorksheet)
                        wbTarget.Worksheets(1).Range("A1:F1").value = Array("日期", "開", "高", "低", "收", "成交量")
                        wbTarget.Worksheets(1).Range("A2").Resize(lastR - 1, 6).value = _
                            exportBook.Worksheets(1).Range("A2:F" & lastR).value
                        wbTarget.Worksheets(1).Range("A2:A" & lastR).NumberFormat = "yyyy-mm-dd hh:mm:ss"
                        wbTarget.Worksheets(1).Range("B2:E" & lastR).NumberFormat = "0.00000"
                        wbTarget.Worksheets(1).Range("F2:F" & lastR).NumberFormat = "#,##0"

                        Dim fullPath As String
                        fullPath = folderPath & symbolStr & "_" & tfName & "_ALL_DATA_" & _
                            Format$(Now, "YYYYMMDD_HHMMSS") & ".csv"
                        wbTarget.SaveAs fullPath, xlCSVUTF8, Local:=True
                        wbTarget.Close False
                        successCount = successCount + 1
                    Else
                        ' 增量抓到0筆是正常的（代表資料庫已是最新），不算失敗
                        If Not isIncremental Then
                            failCount = failCount + 1
                            failList = failList & symbolStr & "-" & tfName & "(無資料) " & vbCrLf
                        End If
                    End If
                    exportBook.Close False
                    Set exportBook = Nothing
                Else
                    failCount = failCount + 1
                    failList = failList & symbolStr & "-" & tfName & "(檔案開啟失敗) " & vbCrLf
                End If
            Else
                failCount = failCount + 1
                failList = failList & symbolStr & "-" & tfName & "(Python執行失敗,ExitCode=" & exitCode & ") " & vbCrLf
            End If
        Next t
    Next s

    Application.StatusBar = False
    Application.ScreenUpdating = True
    Application.DisplayAlerts = True

    Dim resultMsg As String
    resultMsg = "批次匯出完成！" & vbCrLf & vbCrLf & _
                "成功：" & successCount & " 份（增量 " & incrementalCount & " 組 / 整批回補 " & fullCount & " 組）" & vbCrLf & _
                "失敗：" & failCount & " 份"
    If failCount > 0 Then
        resultMsg = resultMsg & vbCrLf & vbCrLf & "失敗明細：" & vbCrLf & failList
    End If
    MsgBox resultMsg, IIf(failCount = 0, vbInformation, vbExclamation), "批次匯出結果"

End Sub

Private Function Quote(ByVal value As String) As String
    Quote = Chr$(34) & value & Chr$(34)
End Function
