Attribute VB_Name = "Module1"
Option Explicit

'====================================================================
' 三大策略終極對接系統（v7 - Excel_Monitor.csv 39欄 + MultiTF_Signals.csv 8列）
' Excel_Monitor.csv 欄位對應(0-based，來自 ExcelMonitor_All.mq5 v1.10)：
'  0 Symbol            1 Bid              2 AsiaLow         3 AsiaHigh
'  4 EuropeLow         5 EuropeHigh       6 USLow           7 USHigh
'  8 WeekSupport       9 WeekResistance  10 RecentSupport  11 RecentResistance
' 12 SupportTouch      13 ResistanceTouch 14 SupportValid   15 ResistanceValid
' 16 ShortMA           17 LongMA          18 EMA            19 ShortMASlopePct
' 20 LongMASlopePct    21 EMASlopePct     22 MAAlignment    23 CrossState
' 24 TrendScore        25 TrendJudgment   26 PersonalSL_ATR
' 27 CurrentVolume     28 AverageVolume   29 VolumeState    30 FinalSignal
' 31 CandlePattern     32 EntrySignal     33 CompositeScore 34 CompositeJudgment
' 35 UpdateTime        36 TodayChangePct
' 37 SessionLevelTest  38 SessionBreakoutJudge   <-- v6新增
'
' 修正紀錄(v6)：
'  - 舊版把 parts(31) 當「更新時間」寫進商品分析報告 AB 欄，但 mq5 那邊
'    早就多輸出了 CandlePattern/EntrySignal/CompositeScore/CompositeJudgment/
'    TodayChangePct 這5欄，parts(31) 實際上已經是 CandlePattern，AB欄長期
'    寫錯資料。這版一併修正，並把新增的 SessionLevelTest/SessionBreakoutJudge
'    也接上。
'
' 修正紀錄(v7)：
'  - MultiTF_Signals.csv 是 optimize.py(Python)寫出來的，預設用UTF-8編碼；
'    但舊版用 Open...For Input 讀檔，VBA會照系統語系(Big5)去解碼，UTF-8的
'    中文字節被Big5誤判，M15/H1共振狀態那兩欄就變成亂碼(例如「憭征銝?」)。
'    改用 ADODB.Stream 以UTF-8明確讀取，不管系統語系是什麼都能正確解碼。
'
' MultiTF_Signals.csv 欄位(來自 optimize.py，用MetaTrader5套件直連算出)：
'  Symbol,M15_Long,M15_Short,M15_Status,H1_Long,H1_Short,H1_Status,UpdateTime
'====================================================================

Public Const DEBUG_MODE As Boolean = False   ' 需要除錯時改成 True，會跳出第一筆資料的欄位內容

Public Sub 手動一鍵更新三大策略報告()

    Dim wb As Workbook
    Dim wsData As Worksheet
    Dim wsReport As Worksheet
    Dim ok As Boolean

    On Error GoTo ERR_HANDLER

    Application.ScreenUpdating = False
    Application.EnableEvents = False
    Application.DisplayAlerts = False

    Set wb = ThisWorkbook

    On Error Resume Next
    Set wsData = wb.Worksheets("Data")
    Set wsReport = wb.Worksheets("商品分析報告")
    On Error GoTo ERR_HANDLER

    If wsData Is Nothing Then
        MsgBox "錯誤：找不到工作表【Data】！", vbCritical, "系統通知"
        GoTo SAFE_EXIT
    End If
    If wsReport Is Nothing Then
        MsgBox "錯誤：找不到工作表【商品分析報告】！", vbCritical, "系統通知"
        GoTo SAFE_EXIT
    End If

    wsData.Range("A2:AM30").ClearContents
    wsReport.Range("A5:AI12").ClearContents

    ok = ImportMT5Data(wsData, wsReport)
    If Not ok Then GoTo SAFE_EXIT

    ' MultiTF(M15/H1)是獨立來源，就算它讀取失敗(例如量化面板還沒跑過)，
    ' 也不影響前面Excel_Monitor.csv這條主線的成功結果，只會讓那6欄留白。
    ImportMultiTFSignals wsReport

    Application.CalculateFull

    wsReport.Range("A3").value = "最後更新時間：" & Format(Now(), "yyyy.mm.dd hh:nn:ss")

    If Application.WorksheetFunction.CountA(wsData.Range("A2:AM30")) = 0 Then
        MsgBox "MT5 CSV 已嘗試讀取，但 Data 工作表仍然沒有任何資料。" & vbCrLf & vbCrLf & _
               "請確認 Excel_Monitor.csv 是否真的有資料。", vbExclamation, "更新失敗"
        GoTo SAFE_EXIT
    End If

    MsgBox "三大策略數據更新完成！" & vbCrLf & vbCrLf & _
           "Data：已寫入" & vbCrLf & "商品分析報告：已同步" & vbCrLf & "公式：已重新計算", _
           vbInformation, "系統通知"

SAFE_EXIT:
    Application.ScreenUpdating = True
    Application.EnableEvents = True
    Application.DisplayAlerts = True
    Exit Sub

ERR_HANDLER:
    MsgBox "更新過程發生錯誤！" & vbCrLf & vbCrLf & _
           "錯誤編號：" & Err.Number & vbCrLf & "錯誤內容：" & Err.Description, _
           vbCritical, "MT5資料更新錯誤"
    Resume SAFE_EXIT

End Sub


Private Function ImportMT5Data(ByVal wsData As Worksheet, ByVal wsReport As Worksheet) As Boolean

    Dim csvPath As String
    Dim lineStr As String
    Dim fileNum As Integer
    Dim rowNum As Long
    Dim colNum As Long
    Dim parts() As String
    Dim cleanVal As String
    Dim fieldCount As Long
    Dim idx As Long, r As Long
    Dim validCount As Long
    Dim isFirstDataLine As Boolean

    On Error GoTo ERR_HANDLER
    ImportMT5Data = False
    isFirstDataLine = True

    csvPath = _
        "C:\Users\user\AppData\Roaming\MetaQuotes\Terminal\" & _
        "81A933A9AFC5DE3C23B15CAB19C63850\MQL5\Files\Excel_Monitor.csv"

    If Len(Dir(csvPath)) = 0 Then
        MsgBox "找不到 MT5 導出的 CSV！" & vbCrLf & vbCrLf & "目前指定路徑：" & vbCrLf & csvPath, _
               vbCritical, "CSV讀取失敗"
        Exit Function
    End If

    fileNum = FreeFile
    Open csvPath For Input As #fileNum

    If EOF(fileNum) Then
        Close #fileNum
        MsgBox "Excel_Monitor.csv 是空檔案！", vbExclamation, "CSV資料為空"
        Exit Function
    End If

    Line Input #fileNum, lineStr   ' 跳過標題列

    rowNum = 2
    validCount = 0

    Do While Not EOF(fileNum)

        Line Input #fileNum, lineStr
        lineStr = Trim$(lineStr)

        If Len(lineStr) > 0 Then

            parts = Split(lineStr, ",")
            fieldCount = UBound(parts) + 1

            If DEBUG_MODE And isFirstDataLine Then
                Dim dbgMsg As String, dbgI As Long
                dbgMsg = "【除錯】CSV 第一筆資料：" & vbCrLf & lineStr & vbCrLf & vbCrLf & _
                         "欄位數：" & fieldCount & vbCrLf & vbCrLf
                For dbgI = 0 To fieldCount - 1
                    dbgMsg = dbgMsg & "parts(" & dbgI & ") = " & parts(dbgI) & vbCrLf
                Next dbgI
                MsgBox dbgMsg, vbInformation, "CSV欄位除錯"
                isFirstDataLine = False
            End If

            If fieldCount < 32 Then
                MsgBox "CSV第 " & (rowNum - 1) & " 筆資料欄位不足！" & vbCrLf & vbCrLf & _
                       "目前欄位數：" & fieldCount & "，要求至少：32 欄" & vbCrLf & vbCrLf & _
                       "原始資料：" & vbCrLf & lineStr, vbExclamation, "CSV欄位錯誤"
                GoTo NEXT_LINE
            End If

            '---------------- 寫入 Data (原樣寫入，欄數依CSV實際內容而定) ----------------
            For colNum = 1 To fieldCount
                cleanVal = Trim$(parts(colNum - 1))
                If Len(cleanVal) = 0 Then
                    wsData.Cells(rowNum, colNum).value = ""
                ElseIf IsNumeric(cleanVal) Then
                    wsData.Cells(rowNum, colNum).value = CDbl(cleanVal)
                Else
                    wsData.Cells(rowNum, colNum).value = cleanVal
                End If
            Next colNum

            '---------------- 寫入 商品分析報告 (curated欄，M15/H1六欄另外由 ImportMultiTFSignals 填) ----------------
            idx = rowNum - 2
            If idx >= 0 And idx <= 7 Then

                r = idx + 5

                wsReport.Cells(r, 1).value = CleanTxt(parts(0))                  ' A 商品
                wsReport.Cells(r, 2).value = SafeCDbl(parts(1))                  ' B Bid
                wsReport.Cells(r, 3).value = SafeCDbl(parts(8))                  ' C 週支撐
                wsReport.Cells(r, 4).value = SafeCDbl(parts(9))                  ' D 週壓力
                wsReport.Cells(r, 5).value = SafeCDbl(parts(10))                 ' E 近支撐
                wsReport.Cells(r, 6).value = SafeCDbl(parts(11))                 ' F 近壓力
                wsReport.Cells(r, 7).value = SafeCDbl(parts(16))                 ' G 短MA
                wsReport.Cells(r, 8).value = SafeCDbl(parts(17))                 ' H 長MA
                wsReport.Cells(r, 9).value = SafeCDbl(parts(18))                 ' I EMA
                wsReport.Cells(r, 10).value = SafeCDbl(parts(19))                ' J 短MA斜率%
                wsReport.Cells(r, 11).value = SafeCDbl(parts(20))                ' K 長MA斜率%
                wsReport.Cells(r, 12).value = SafeCDbl(parts(21))                ' L EMA斜率%
                wsReport.Cells(r, 13).value = CleanTxt(parts(22))                ' M 均線排列
                wsReport.Cells(r, 14).value = CleanTxt(parts(23))                ' N 交叉狀態
                wsReport.Cells(r, 15).value = SafeCLng(parts(24))                ' O 趨勢分數
                wsReport.Cells(r, 16).value = CleanTxt(parts(25))                ' P 趨勢判定
                wsReport.Cells(r, 17).value = SafeCDbl(parts(26))                ' Q 個人化SL(ATR)
                wsReport.Cells(r, 18).value = SafeCLng(parts(27))                ' R 目前量
                wsReport.Cells(r, 19).value = SafeCDbl(parts(28))                ' S 平均量
                wsReport.Cells(r, 20).value = CleanTxt(parts(29))                ' T 量能狀態
                wsReport.Cells(r, 21).value = CleanTxt(parts(30))                ' U 最終訊號
                ' V~AA(M15/H1共振) 由 ImportMultiTFSignals 另外填入

                ' AB~AI：v6新增／修正，欄數不足的舊CSV就跳過，不會報錯
                If fieldCount >= 39 Then
                    wsReport.Cells(r, 28).value = CleanTxt(parts(31))            ' AB K棒型態(修正：原本誤當成更新時間)
                    wsReport.Cells(r, 29).value = CleanTxt(parts(32))            ' AC 進場建議
                    wsReport.Cells(r, 30).value = SafeCDbl(parts(33))            ' AD 11指標綜合分數
                    wsReport.Cells(r, 31).value = CleanTxt(parts(34))            ' AE 11指標綜合判定
                    wsReport.Cells(r, 32).value = CleanTxt(parts(35))            ' AF 更新時間(正確欄位)
                    wsReport.Cells(r, 33).value = SafeCDbl(parts(36))            ' AG 今日漲跌%
                    wsReport.Cells(r, 34).value = CleanTxt(parts(37))            ' AH 關鍵位測試
                    wsReport.Cells(r, 35).value = CleanTxt(parts(38))            ' AI 突破判斷
                    wsReport.Cells(r, 30).NumberFormat = "0.00"
                    wsReport.Cells(r, 33).NumberFormat = "0.00"
                End If

                ' 數字格式：日圓/黃金用較少小數位，其餘用5位
                Dim symTxt As String
                symTxt = CleanTxt(parts(0))
                If symTxt = "USDJPY" Or symTxt = "XAUUSD" Then
                    wsReport.Range(wsReport.Cells(r, 2), wsReport.Cells(r, 9)).NumberFormat = "0.00"
                    wsReport.Cells(r, 17).NumberFormat = "0.00"
                Else
                    wsReport.Range(wsReport.Cells(r, 2), wsReport.Cells(r, 9)).NumberFormat = "0.00000"
                    wsReport.Cells(r, 17).NumberFormat = "0.00000"
                End If
                wsReport.Range(wsReport.Cells(r, 10), wsReport.Cells(r, 12)).NumberFormat = "0.0000"

                validCount = validCount + 1
            End If

        End If

NEXT_LINE:
        rowNum = rowNum + 1
        If rowNum > 30 Then Exit Do

    Loop

    Close #fileNum

    If validCount = 0 Then
        MsgBox "CSV 有資料，但沒有成功寫入 8 大商品報告。" & vbCrLf & vbCrLf & _
               "請檢查 CSV 第一行之後是否真的包含 8 筆商品資料。", vbExclamation, "匯入失敗"
        Exit Function
    End If

    ImportMT5Data = True
    Exit Function

ERR_HANDLER:
    On Error Resume Next
    If fileNum > 0 Then Close #fileNum
    On Error GoTo 0
    MsgBox "MT5 CSV 匯入發生錯誤！" & vbCrLf & vbCrLf & _
           "錯誤編號：" & Err.Number & vbCrLf & "錯誤內容：" & Err.Description & vbCrLf & vbCrLf & _
           "目前處理 Data 第 " & rowNum & " 列。", vbCritical, "CSV匯入錯誤"
    ImportMT5Data = False

End Function


'====================================================================
' 讀取「量化回測主控面板」optimize.py 算出來的 MultiTF_Signals.csv，
' 依商品名稱比對，把 M15/H1 共振結果填進商品分析報告的 V~AA 欄。
' 找不到檔案或商品對不上都不會報錯中斷，只是那幾欄留空，不影響主流程。
'====================================================================
Private Sub ImportMultiTFSignals(ByVal wsReport As Worksheet)

    Dim csvPath As String
    Dim lines() As String
    Dim lineStr As String
    Dim parts() As String
    Dim i As Long
    Dim isHeader As Boolean

    csvPath = "D:\資料查詢\MultiTF_Signals.csv"

    If Len(Dir(csvPath)) = 0 Then Exit Sub   ' 量化面板還沒跑過，安靜跳過

    On Error GoTo ERR_HANDLER

    lines = ReadFileUTF8Lines(csvPath)

    isHeader = True
    For i = LBound(lines) To UBound(lines)
        lineStr = Trim$(lines(i))

        If isHeader Then
            isHeader = False
        ElseIf Len(lineStr) > 0 Then

            parts = Split(lineStr, ",")
            If UBound(parts) >= 7 Then

                Dim sym As String
                sym = CleanTxt(parts(0))

                Dim r As Long
                r = FindReportRowBySymbol(wsReport, sym)

                If r > 0 Then
                    wsReport.Cells(r, 22).value = SafeCLng(parts(1))     ' V M15多頭票
                    wsReport.Cells(r, 23).value = SafeCLng(parts(2))     ' W M15空頭票
                    wsReport.Cells(r, 24).value = CleanTxt(parts(3))     ' X M15共振狀態
                    wsReport.Cells(r, 25).value = SafeCLng(parts(4))     ' Y H1多頭票
                    wsReport.Cells(r, 26).value = SafeCLng(parts(5))     ' Z H1空頭票
                    wsReport.Cells(r, 27).value = CleanTxt(parts(6))     ' AA H1共振狀態
                End If

            End If
        End If
    Next i

    Exit Sub

ERR_HANDLER:
    ' 這個來源失敗不彈錯誤視窗，安靜略過即可(不影響主流程)

End Sub

' 用 ADODB.Stream 以UTF-8明確讀取整個文字檔並拆成行陣列，
' 不像 Open...For Input 那樣受系統語系(Big5/ANSI)影響而導致中文亂碼。
Private Function ReadFileUTF8Lines(ByVal path As String) As String()
    Dim stream As Object
    Dim content As String

    Set stream = CreateObject("ADODB.Stream")
    stream.Type = 2            ' adTypeText
    stream.Charset = "utf-8"
    stream.Open
    stream.LoadFromFile path
    content = stream.ReadText
    stream.Close

    ' 去掉UTF-8 BOM(如果檔案開頭有的話)
    If Len(content) > 0 Then
        If AscW(Left$(content, 1)) = 65279 Then content = Mid$(content, 2)
    End If

    content = Replace(content, vbCrLf, vbLf)
    content = Replace(content, vbCr, vbLf)
    ReadFileUTF8Lines = Split(content, vbLf)
End Function

Private Function FindReportRowBySymbol(ByVal wsReport As Worksheet, ByVal sym As String) As Long
    Dim r As Long
    For r = 5 To 12
        If CleanTxt(CStr(wsReport.Cells(r, 1).value)) = sym Then
            FindReportRowBySymbol = r
            Exit Function
        End If
    Next r
    FindReportRowBySymbol = 0
End Function


Private Function SafeCDbl(ByVal value As String) As Double
    Dim s As String
    s = Trim$(value)
    If Len(s) = 0 Then
        SafeCDbl = 0#
    ElseIf IsNumeric(s) Then
        SafeCDbl = CDbl(s)
    Else
        SafeCDbl = 0#
    End If
End Function

Private Function SafeCLng(ByVal value As String) As Long
    Dim s As String
    s = Trim$(value)
    If Len(s) = 0 Then
        SafeCLng = 0
    ElseIf IsNumeric(s) Then
        SafeCLng = CLng(CDbl(s))
    Else
        SafeCLng = 0
    End If
End Function

Private Function CleanTxt(ByVal value As String) As String
    Dim s As String
    s = Trim$(value)
    s = Replace(s, Chr$(34), "")
    s = Replace(s, vbCr, "")
    s = Replace(s, vbLf, "")
    CleanTxt = Trim$(s)
End Function
