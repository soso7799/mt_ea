' =============================================
' Module1 - 主控更新模組（v12：儀表板加今日開盤價/漲跌%/淨多空得分/資料新鮮度、波段避險分組/總整理、開檔自動載入資料、關卡 ±0.015% 上色、下拉換商品自動更新；G 槽路徑、UTF-8 讀檔、一鍵全部更新、錯誤直接顯示）
' 使用方式：按儀表板上的按鈕（或 Alt+F8 執行「更新關卡」/「全部更新」），一次跑完全部。
' =============================================
Option Explicit


' ===== 路徑請依您電腦修改 =====
Const PY_EXE As String = "python"                                  ' 若無效改成完整路徑，例如 C:\Python312\python.exe
Const BASE_DIR As String = "G:\我的雲端硬碟\整理後\"
Const PY_SCRIPT2 As String = "G:\我的雲端硬碟\整理後\compute_indicators.py"   ' 產生 multi_symbol_status.csv
Const PY_SCRIPT3 As String = "G:\我的雲端硬碟\整理後\make_levels.py"          ' 產生 today_open.csv / session_levels.csv
Const OUT_DIR As String = "G:\我的雲端硬碟\整理後\update_output\"
Const CSV_OPEN As String = "G:\我的雲端硬碟\整理後\update_output\today_open.csv"
Const CSV_LEVELS As String = "G:\我的雲端硬碟\整理後\update_output\session_levels.csv"
Const CSV_STATUS As String = "G:\我的雲端硬碟\整理後\update_output\multi_symbol_status.csv"
Const STALE_THRESHOLD_MINUTES As Double = 15   ' 資料時間比現在晚超過這個分鐘數，就在關卡標紅警告過期
' ==============================

' ===== RefreshDashboard 用常數 =====
Private Const SL_RANGE_FACTOR As Double = 0.4      ' 基準SL = 當日波動範圍 * 這個比例
Private Const RATIO_MAX_VALUE As Double = 500      ' MA/MACD/BOLL/KELTNER 每段數值上限，超過視為異常
Private Const DASH_COL_A_WIDTH As Double = 12      ' AutoFit 之後，A欄固定寬度
Private Const NEAR_LEVEL_PCT As Double = 0.015     ' 關卡表：關卡價與現價相差在 ±這個 % 以內就上色
' ==============================

Private gReport As String    ' 各步驟的結果訊息，最後一次顯示
Private gQuiet As Boolean    ' True = 由「全部更新」呼叫，各步驟不各自跳視窗
Private gHook As clsDash       ' 監聽儀表板 B5（換商品自動更新畫面）

' ---------- 其他工作表對應的 CSV 檔名（檔名不對就改這裡） ----------
Private Function ImportList() As Variant
    ' 每一組：CSV 檔名, 工作表名稱, 表頭在第幾列
    ImportList = Array( _
        Array("multi_symbol_status.csv", "多商品狀態總表", 1), _
        Array("multi_symbol_params.csv", "多商品參數優化", 1), _
        Array("multi_symbol_session_levels.csv", "多商品時段壓力支撐", 1), _
        Array("multi_symbol_backtest_summary.csv", "多商品回測摘要", 1), _
        Array("multi_symbol_trades.csv", "多商品交易明細", 1), _
        Array("multi_symbol_entry_signals.csv", "多商品進場信號", 1), _
        Array("hedge_groups.csv", "波段避險分組", 5), _
        Array("summary_all.csv", "總整理", 1))
End Function

' =============================================
' ★ 一鍵全部更新：Python → 匯入CSV → 關卡 → 儀表板
' =============================================
Public Sub 全部更新()
    gReport = ""
    gQuiet = True
    Application.ScreenUpdating = False

    Call RunPythonUpdate
    Call ImportAllCsv
    Call Update關卡
    Call RefreshDashboard

    Application.ScreenUpdating = True
    gQuiet = False
    Call 掛上換商品監聽
    MsgBox "全部更新完成 " & Format(Now, "yyyy-mm-dd hh:nn:ss") & vbCrLf & vbCrLf & gReport, vbInformation
End Sub

' ---------- 執行 Python（每支腳本的輸出寫在 update_output\log_*.txt） ----------
Private Sub RunPythonUpdate()
    Dim wsh As Object
    Set wsh = CreateObject("WScript.Shell")
    On Error Resume Next
    wsh.CurrentDirectory = BASE_DIR   ' 讓 Python 的相對路徑正確
    On Error GoTo 0

    Call RunOneScript(wsh, PY_SCRIPT2)
    Call RunOneScript(wsh, PY_SCRIPT3)

    If Not gQuiet Then ShowReport "Python 執行結果"
End Sub

' 每支腳本各自一個 log：update_output\log_<腳本名>.txt；失敗時把最後幾行錯誤直接顯示出來
Private Sub RunOneScript(wsh As Object, script As String)
    Dim nm As String, logPath As String, rc As Long
    nm = Mid$(script, InStrRev(script, "\") + 1)
    If Dir$(script) = "" Then
        AddReport "【Python】找不到 " & script
        Exit Sub
    End If
    logPath = OUT_DIR & "log_" & Replace(nm, ".py", "") & ".txt"
    rc = RunPy(wsh, script, logPath)
    If rc = 0 Then
        AddReport "【Python】" & nm & " 完成"
    Else
        AddReport "【Python】" & nm & " 失敗（代碼 " & rc & "）：" & vbCrLf & LogTail(logPath, 6)
    End If
End Sub

Private Function RunPy(wsh As Object, script As String, logPath As String) As Long
    Dim cmd As String
    cmd = "cmd /c ""set PYTHONIOENCODING=utf-8&& """ & PY_EXE & """ """ & script & """" & _
          " > """ & logPath & """ 2>&1"""
    On Error GoTo Fail
    RunPy = wsh.Run(cmd, 0, True)
    Exit Function
Fail:
    RunPy = -1
End Function

Private Function LogTail(path As String, n As Long) As String
    On Error GoTo Fail
    If Dir$(path) = "" Then
        LogTail = "   （沒有 log 檔）"
        Exit Function
    End If
    Dim lines As Variant, i As Long, k As Long, out As String
    lines = ReadUtf8Lines(path)
    For i = UBound(lines) To LBound(lines) Step -1
        If Len(Trim$(lines(i))) > 0 Then
            out = "   " & Trim$(lines(i)) & vbCrLf & out
            k = k + 1
            If k >= n Then Exit For
        End If
    Next i
    LogTail = out
    Exit Function
Fail:
    LogTail = "   （讀不到 log：" & path & "）"
End Function

' =============================================
' 匯入所有 CSV 到對應工作表（UTF-8，不會亂碼）
' =============================================
Private Sub ImportAllCsv()
    Dim lst As Variant, i As Long
    lst = ImportList()
    For i = LBound(lst) To UBound(lst)
        Call ImportCsvToSheet(OUT_DIR & lst(i)(0), CStr(lst(i)(1)), CLng(lst(i)(2)))
    Next i
    If Not gQuiet Then ShowReport "CSV 匯入結果"
End Sub

Private Sub ImportCsvToSheet(csvPath As String, sheetName As String, headerRow As Long)
    On Error GoTo ErrHandler
    Dim ws As Worksheet
    Set ws = Application.ThisWorkbook.Worksheets(sheetName)

    If Dir$(csvPath) = "" Then
        AddReport "【" & sheetName & "】找不到 " & csvPath & "（此表未更新）"
        Exit Sub
    End If

    Dim lines As Variant, cols As Variant
    lines = ReadUtf8Lines(csvPath)

    ' 清掉舊資料（表頭以下全部）
    Dim lastRow As Long, lastCol As Long
    If Not ws.Cells.Find("*", , xlValues, , xlByRows, xlPrevious) Is Nothing Then
        lastRow = ws.Cells.Find("*", , xlValues, , xlByRows, xlPrevious).Row
        lastCol = ws.Cells.Find("*", , xlValues, , xlByColumns, xlPrevious).Column
        If lastRow > headerRow Then ws.Range(ws.Cells(headerRow + 1, 1), ws.Cells(lastRow, lastCol)).Clear
    End If

    Dim i As Long, j As Long, outRow As Long, isHeader As Boolean
    isHeader = True
    outRow = headerRow
    For i = LBound(lines) To UBound(lines)
        If Len(Trim$(lines(i))) > 0 Then
            cols = SplitCsvLine(CStr(lines(i)))
            If Not isHeader And Trim$(cols(0)) = "" Then GoTo NextLine   ' 第一欄(商品)空白的列跳過
            For j = 0 To UBound(cols)
                If isHeader Then
                    ws.Cells(headerRow, j + 1).Value = Trim$(cols(j))
                Else
                    Call PutCell(ws.Cells(outRow, j + 1), CStr(cols(j)))
                End If
            Next j
            isHeader = False
            outRow = outRow + 1
        End If
NextLine:
    Next i

    AddReport "【" & sheetName & "】" & (outRow - headerRow - 1) & " 列"
    Exit Sub

ErrHandler:
    AddReport "【" & sheetName & "】匯入錯誤：" & Err.Description
End Sub

' 依內容決定寫入型態：日期 / 數字 / 文字（文字強制文字格式，避免 12/26/9 被 Excel 變成日期）
Private Sub PutCell(c As Range, ByVal s As String)
    s = Trim$(s)
    If s = "" Then Exit Sub
    Dim d As Variant
    d = ParseDate(s)
    If Not IsEmpty(d) Then
        c.NumberFormat = "yyyy-mm-dd hh:mm"
        c.Value = d
    ElseIf IsPlainNumber(s) Then
        c.Value = Val(s)
    Else
        c.NumberFormat = "@"
        c.Value = s
    End If
End Sub

Private Function IsPlainNumber(s As String) As Boolean
    If s Like "*[!0-9.eE+-]*" Then Exit Function
    IsPlainNumber = IsNumeric(s)
End Function

' 只接受 yyyy-mm-dd 開頭的字串當日期，失敗回傳 Empty
Private Function ParseDate(ByVal s As String) As Variant
    ParseDate = Empty
    s = Trim$(s)
    If Not (s Like "####-##-##*") Then Exit Function
    s = Replace(s, "T", " ")
    If Len(s) > 19 Then s = Left$(s, 19)
    On Error Resume Next
    ParseDate = CDate(s)
    If Err.Number <> 0 Then ParseDate = Empty
    On Error GoTo 0
End Function

' ---------- 以 UTF-8 讀整個文字檔，回傳每一行 ----------
Private Function ReadUtf8Lines(path As String) As Variant
    Dim stm As Object, txt As String
    Set stm = CreateObject("ADODB.Stream")
    stm.Type = 2
    stm.Charset = "utf-8"
    stm.Open
    stm.LoadFromFile path
    txt = stm.ReadText(-1)
    stm.Close
    If Len(txt) > 0 Then
        If AscW(Left$(txt, 1)) = &HFEFF Then txt = Mid$(txt, 2)
    End If
    txt = Replace(txt, vbCrLf, vbLf)
    txt = Replace(txt, vbCr, vbLf)
    ReadUtf8Lines = Split(txt, vbLf)
End Function

' ---------- 切 CSV 一行（支援雙引號包起來的欄位） ----------
Private Function SplitCsvLine(ln As String) As Variant
    Dim res() As String, n As Long, i As Long, ch As String, cur As String, inQ As Boolean
    ReDim res(0 To 0)
    For i = 1 To Len(ln)
        ch = Mid$(ln, i, 1)
        If inQ Then
            If ch = """" Then
                If Mid$(ln, i + 1, 1) = """" Then
                    cur = cur & """"
                    i = i + 1
                Else
                    inQ = False
                End If
            Else
                cur = cur & ch
            End If
        Else
            If ch = """" Then
                inQ = True
            ElseIf ch = "," Then
                ReDim Preserve res(0 To n)
                res(n) = cur
                n = n + 1
                cur = ""
            Else
                cur = cur & ch
            End If
        End If
    Next i
    ReDim Preserve res(0 To n)
    res(n) = cur
    SplitCsvLine = res
End Function

' =============================================
' 儀表板按鈕綁的是這個名稱：直接跑全部更新
' =============================================
Public Sub 更新關卡()
    Call 全部更新
End Sub

Private Sub Update關卡()
    On Error GoTo ErrHandler
    Dim ws As Worksheet
    Dim dictOpen As Collection, dictClose As Collection
    Dim dictAH As Collection, dictAL As Collection
    Dim dictEH As Collection, dictEL As Collection
    Dim dictUH As Collection, dictUL As Collection
    Dim dictPDH As Collection, dictPDL As Collection
    Dim dictRS As Collection, dictRR As Collection
    Dim dictDataAsOf As Collection
    Dim i As Long, lastRow As Long, hitCount As Long
    Dim sym As String
    Dim openP As Double, price As Double, chg As Double
    Dim dataAsOf As Variant, staleMinutes As Double

    Set ws = Application.ThisWorkbook.Worksheets("關卡")

    Set dictOpen = New Collection
    Set dictClose = New Collection
    Set dictAH = New Collection
    Set dictAL = New Collection
    Set dictEH = New Collection
    Set dictEL = New Collection
    Set dictUH = New Collection
    Set dictUL = New Collection
    Set dictPDH = New Collection
    Set dictPDL = New Collection
    Set dictRS = New Collection
    Set dictRR = New Collection
    Set dictDataAsOf = New Collection


    ' 讀 today_open.csv  (Symbol,TodayOpen,LatestClose,DataAsOf)
    Call LoadCsvMulti(CSV_OPEN, dictOpen, 1, 2)      ' Symbol -> TodayOpen
    Call LoadCsvMulti(CSV_OPEN, dictClose, 1, 3)     ' Symbol -> LatestClose
    Call LoadCsvMulti(CSV_OPEN, dictDataAsOf, 1, 4)  ' Symbol -> DataAsOf

    ' 讀 session_levels.csv
    Call LoadCsvMulti(CSV_LEVELS, dictAH, 1, 3)   ' Asian_High
    Call LoadCsvMulti(CSV_LEVELS, dictAL, 1, 4)   ' Asian_Low
    Call LoadCsvMulti(CSV_LEVELS, dictEH, 1, 5)   ' European_High
    Call LoadCsvMulti(CSV_LEVELS, dictEL, 1, 6)   ' European_Low
    Call LoadCsvMulti(CSV_LEVELS, dictUH, 1, 7)   ' US_High
    Call LoadCsvMulti(CSV_LEVELS, dictUL, 1, 8)   ' US_Low
    Call LoadCsvMulti(CSV_LEVELS, dictPDH, 1, 9)  ' PrevDay_High
    Call LoadCsvMulti(CSV_LEVELS, dictPDL, 1, 10) ' PrevDay_Low
    Call LoadCsvMulti(CSV_LEVELS, dictRS, 1, 12)  ' Recent_Support
    Call LoadCsvMulti(CSV_LEVELS, dictRR, 1, 13)  ' Recent_Resistance

    If dictAH.Count = 0 Then AddReport "【關卡】session_levels.csv 是空的（Python 沒產生），亞歐美盤/前日高低/支撐壓力無資料"

    ' today_open.csv 空的 → 改用「多商品狀態總表」M5 最新收盤價與時間
    If dictClose.Count = 0 Then
        AddReport "【關卡】today_open.csv 是空的（Python 沒產生），即時Bid/資料時間改用多商品狀態總表 M5，今日開盤無資料"
        Dim wsS As Worksheet, rS As Long, k As String
        Set wsS = Application.ThisWorkbook.Worksheets("多商品狀態總表")
        For rS = 2 To wsS.Cells(wsS.Rows.Count, 1).End(xlUp).Row
            k = Trim(CStr(wsS.Cells(rS, 1).Value))
            If k <> "" And Trim(CStr(wsS.Cells(rS, 2).Value)) = "M5" Then
                If Not CollExists(dictClose, k) Then dictClose.Add CStr(wsS.Cells(rS, 4).Value), k
                If IsDate(wsS.Cells(rS, 3).Value) And Not CollExists(dictDataAsOf, k) Then
                    dictDataAsOf.Add Format(wsS.Cells(rS, 3).Value, "yyyy-mm-dd hh:nn:ss"), k
                End If
            End If
        Next rS
    End If

    lastRow = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    For i = 2 To lastRow
        sym = Trim(CStr(ws.Cells(i, 1).Value))
        If sym = "" Then GoTo NextI

        ' 即時 Bid (col 2)
        If CollExists(dictClose, sym) Then
            price = Val(dictClose(sym))
            ws.Cells(i, 2).Value = price
            hitCount = hitCount + 1
        Else
            price = Val(ws.Cells(i, 2).Value)
        End If

        ' 今日開盤 (col 3)
        If CollExists(dictOpen, sym) Then
            openP = Val(dictOpen(sym))
            ws.Cells(i, 3).Value = openP
        Else
            openP = Val(ws.Cells(i, 3).Value)
        End If

        ' 漲跌% (col 4)
        If openP > 0 And price > 0 Then
            chg = Round((price - openP) / openP * 100, 3)
            ws.Cells(i, 4).Value = chg
            If chg > 0 Then
                ws.Cells(i, 2).Interior.Color = RGB(198, 239, 206)
                ws.Cells(i, 4).Interior.Color = RGB(198, 239, 206)
                ws.Cells(i, 2).Font.Color = RGB(0, 97, 0)
                ws.Cells(i, 4).Font.Color = RGB(0, 97, 0)
            ElseIf chg < 0 Then
                ws.Cells(i, 2).Interior.Color = RGB(255, 199, 206)
                ws.Cells(i, 4).Interior.Color = RGB(255, 199, 206)
                ws.Cells(i, 2).Font.Color = RGB(156, 0, 6)
                ws.Cells(i, 4).Font.Color = RGB(156, 0, 6)
            End If
        End If

        ' 亞歐美高低 + 前日高低點 + 近支撐壓力 (col 5~14)
        If CollExists(dictAL, sym) Then ws.Cells(i, 5).Value = Val(dictAL(sym))
        If CollExists(dictAH, sym) Then ws.Cells(i, 6).Value = Val(dictAH(sym))
        If CollExists(dictEL, sym) Then ws.Cells(i, 7).Value = Val(dictEL(sym))
        If CollExists(dictEH, sym) Then ws.Cells(i, 8).Value = Val(dictEH(sym))
        If CollExists(dictUL, sym) Then ws.Cells(i, 9).Value = Val(dictUL(sym))
        If CollExists(dictUH, sym) Then ws.Cells(i, 10).Value = Val(dictUH(sym))
        If CollExists(dictPDH, sym) Then ws.Cells(i, 11).Value = Val(dictPDH(sym))  ' K欄 = 前日高點
        If CollExists(dictPDL, sym) Then ws.Cells(i, 12).Value = Val(dictPDL(sym))  ' L欄 = 前日低點
        If CollExists(dictRS, sym) Then ws.Cells(i, 13).Value = Val(dictRS(sym))
        If CollExists(dictRR, sym) Then ws.Cells(i, 14).Value = Val(dictRR(sym))

        ' 關卡價接近現價（±NEAR_LEVEL_PCT %）上色：在現價上方＝紅（壓力）、下方＝綠（支撐）
        Call ColorNearLevels(ws, i, price)

        ' 更新時間 (col 15)：巨集執行時間，不代表資料是新的
        ws.Cells(i, 15).Value = Format(Now, "yyyy-mm-dd hh:nn:ss")

        ' 資料新鮮度 (col 16)
        dataAsOf = Empty
        If CollExists(dictDataAsOf, sym) Then dataAsOf = ParseDate(CStr(dictDataAsOf(sym)))
        If Not IsEmpty(dataAsOf) Then
            staleMinutes = (Now - dataAsOf) * 24 * 60
            If staleMinutes > STALE_THRESHOLD_MINUTES Then
                ws.Cells(i, 16).Value = "已過期 " & Format(staleMinutes / 60, "0.0") & " 小時（資料庫沒更新，突破/反轉判斷不可信）"
                ws.Cells(i, 16).Interior.Color = RGB(255, 0, 0)
                ws.Cells(i, 16).Font.Color = RGB(255, 255, 255)
                ws.Cells(i, 16).Font.Bold = True
            Else
                ws.Cells(i, 16).Value = "正常（" & Format(staleMinutes, "0") & "分鐘前）"
                ws.Cells(i, 16).Interior.Color = RGB(198, 239, 206)
                ws.Cells(i, 16).Font.Color = RGB(0, 97, 0)
                ws.Cells(i, 16).Font.Bold = False
            End If
        Else
            ws.Cells(i, 16).Value = "查無資料時間"
            ws.Cells(i, 16).Interior.Color = RGB(255, 235, 156)
            ws.Cells(i, 16).Font.Color = RGB(0, 0, 0)
            ws.Cells(i, 16).Font.Bold = False
        End If
NextI:
    Next i

    AddReport "【關卡】" & hitCount & " / " & (lastRow - 1) & " 個商品有資料"
    Exit Sub

ErrHandler:
    AddReport "【關卡】錯誤：" & Err.Description
End Sub

' ---------- 關卡表第 r 列：E~N 欄的關卡價與現價比較，±NEAR_LEVEL_PCT % 以內上色 ----------
Private Sub ColorNearLevels(ws As Worksheet, r As Long, price As Double)
    Dim c As Long, v As Double, d As Double
    For c = 5 To 14
        With ws.Cells(r, c)
            .Interior.Pattern = xlNone
            .Font.Color = RGB(0, 0, 0)
            .Font.Bold = False
            If price > 0 And IsNumeric(.Value) And Not IsEmpty(.Value) Then
                v = CDbl(.Value)
                If v > 0 Then
                    d = Round((v - price) / price * 100, 6)
                    If Abs(d) <= NEAR_LEVEL_PCT Then
                        If v >= price Then
                            .Interior.Color = RGB(255, 199, 206)   ' 在現價上方（壓力）
                            .Font.Color = RGB(156, 0, 6)
                        Else
                            .Interior.Color = RGB(198, 239, 206)   ' 在現價下方（支撐）
                            .Font.Color = RGB(0, 97, 0)
                        End If
                        .Font.Bold = True
                    End If
                End If
            End If
        End With
    Next c
End Sub

' ---------- 讀 CSV 單一欄到 Collection（UTF-8，key -> value） ----------
Private Sub LoadCsvMulti(csvPath As String, dict As Collection, keyCol As Long, valCol As Long)
    If Dir$(csvPath) = "" Then Exit Sub

    Dim lines As Variant, cols As Variant, i As Long
    Dim k As String, v As String
    lines = ReadUtf8Lines(csvPath)
    For i = LBound(lines) + 1 To UBound(lines)   ' 第一行是表頭
        If Len(Trim$(lines(i))) > 0 Then
            cols = SplitCsvLine(CStr(lines(i)))
            If UBound(cols) >= (keyCol - 1) And UBound(cols) >= (valCol - 1) Then
                k = Trim$(cols(keyCol - 1))
                v = Trim$(cols(valCol - 1))
                If k <> "" Then
                    If Not CollExists(dict, k) Then dict.Add v, k
                End If
            End If
        End If
    Next i
End Sub

' ---------- 檢查 Collection 裡是否已有某個 key ----------
Private Function CollExists(coll As Collection, key As String) As Boolean
    On Error Resume Next
    Dim tmp As Variant
    tmp = coll(key)
    CollExists = (Err.Number = 0)
    Err.Clear
End Function

' ---------- 訊息彙整 ----------
Private Sub AddReport(msg As String)
    gReport = gReport & msg & vbCrLf
End Sub

Private Sub ShowReport(title As String)
    If gReport <> "" Then MsgBox gReport, vbInformation, title
    gReport = ""
End Sub

' =============================================
' RefreshDashboard
' 依據 B5 選擇的商品，從「多商品狀態總表」「多商品參數優化」「關卡」
' 篩選/彙整寫入「儀表板總表」。
' =============================================
Private Sub RefreshDashboard()
    On Error GoTo ErrHandler
    Application.ScreenUpdating = False

    Dim wsDash As Worksheet, wsStatus As Worksheet, wsParams As Worksheet, wsLevels As Worksheet
    Set wsDash = Application.ThisWorkbook.Worksheets("儀表板總表")
    Set wsStatus = Application.ThisWorkbook.Worksheets("多商品狀態總表")
    Set wsParams = Application.ThisWorkbook.Worksheets("多商品參數優化")
    Set wsLevels = Application.ThisWorkbook.Worksheets("關卡")

    Dim symbol As String
    symbol = Trim(wsDash.Range("B5").Value)
    If symbol = "" Then
        AddReport "【儀表板】請先在 B5 選擇商品！"
        GoTo Finalize
    End If

    Dim runTime As Date: runTime = Now()
    Dim paramHits As Long, statusHits As Long

    Dim periods As Variant: periods = Array("D1", "H4", "H1", "M15", "M5")
    Dim weights As Variant: weights = Array("35%", "25%", "20%", "12%", "8%")
    Dim slMul As Variant: slMul = Array(1#, 0.7, 0.5, 0.3, 0.15)

    Dim lastRowL As Long: lastRowL = wsLevels.Cells(wsLevels.Rows.Count, 1).End(xlUp).Row
    Dim baseSL As Double: baseSL = 0
    Dim hasRangeData As Boolean: hasRangeData = False
    Dim rL As Long
    Dim dayHigh As Double, dayLow As Double
    For rL = 2 To lastRowL
        If Trim(CStr(wsLevels.Cells(rL, 1).Value)) = symbol Then
            dayHigh = Val(wsLevels.Cells(rL, 11).Value)
            dayLow = Val(wsLevels.Cells(rL, 12).Value)
            If dayHigh > 0 And dayLow > 0 And dayHigh > dayLow Then
                baseSL = (dayHigh - dayLow) * SL_RANGE_FACTOR
                hasRangeData = True
            End If
            Exit For
        End If
    Next rL

    Dim lastRowP As Long: lastRowP = wsParams.Cells(wsParams.Rows.Count, 1).End(xlUp).Row
    Dim lastRowS As Long: lastRowS = wsStatus.Cells(wsStatus.Rows.Count, 1).End(xlUp).Row

    Dim pIdx As Long, period As String, rA As Long, rB As Long, rC As Long, r As Long
    Dim slEst As Double, tpEst As Double
    Dim sumWin As Double, sumAlpha As Double, cntInd As Long
    Dim indName As String, bpRaw As Variant, bp As String, winPct As Variant, alphaV As Variant
    Dim cleanS As String, maParts() As String, bStart As Long, bEnd As Long
    Dim longV As Long, shortV As Long, sig As String

    ' 今日開盤價（today_open.csv）＋資料新鮮度（multi_symbol_status.csv 的存檔時間，跟本機時間比）
    Dim dOpen As New Collection, todayOpen As Double, lastClose As Double
    Call LoadCsvMulti(CSV_OPEN, dOpen, 1, 2)
    todayOpen = 0
    If CollExists(dOpen, symbol) Then todayOpen = Val(dOpen(symbol))
    Dim freshTxt As String, ageMin As Double
    freshTxt = "無資料"
    If Dir$(CSV_STATUS) <> "" Then
        ageMin = (Now() - CDate(FileDateTime(CSV_STATUS))) * 1440#
        If ageMin <= STALE_THRESHOLD_MINUTES Then
            freshTxt = "新鮮（" & Format(ageMin, "0") & " 分鐘前）"
        Else
            freshTxt = "過期（" & Format(ageMin, "0") & " 分鐘前）"
        End If
    End If
    wsDash.Range("J14").Value = "今日開盤價"
    wsDash.Range("K14").Value = "今日開盤至今漲跌%"
    wsDash.Range("L14").Value = "淨多空得分"
    wsDash.Range("M14").Value = "資料新鮮度"
    wsDash.Range("J14:M14").Font.Bold = True

    For pIdx = 0 To UBound(periods)
        period = periods(pIdx)

        rA = 7 + pIdx
        wsDash.Range(wsDash.Cells(rA, 3), wsDash.Cells(rA, 20)).ClearContents
        wsDash.Cells(rA, 1).Value = symbol
        wsDash.Cells(rA, 2).Value = period

        If hasRangeData Then
            slEst = baseSL * slMul(pIdx)
            tpEst = slEst * 2#
            wsDash.Cells(rA, 3).NumberFormat = "0.00000"
            wsDash.Cells(rA, 3).Value = slEst
            wsDash.Cells(rA, 4).NumberFormat = "0.00000"
            wsDash.Cells(rA, 4).Value = tpEst
        Else
            wsDash.Cells(rA, 3).Value = "無關卡資料"
            wsDash.Cells(rA, 4).Value = "無關卡資料"
        End If

        sumWin = 0: sumAlpha = 0: cntInd = 0

        For r = 2 To lastRowP
            If Trim(CStr(wsParams.Cells(r, 1).Value)) = symbol And Trim(CStr(wsParams.Cells(r, 2).Value)) = period Then
                paramHits = paramHits + 1
                indName = UCase(Trim(CStr(wsParams.Cells(r, 3).Value)))
                bpRaw = wsParams.Cells(r, 4).Value
                bp = Trim(CStr(bpRaw))
                winPct = wsParams.Cells(r, 5).Value
                alphaV = wsParams.Cells(r, 7).Value

                Select Case indName
                    Case "MA"
                        If ValidateRatio(bpRaw, 2, cleanS) Then
                            maParts = Split(cleanS, "/")
                            wsDash.Cells(rA, 5).Value = Val(maParts(0))
                            wsDash.Cells(rA, 6).Value = Val(maParts(1))
                        Else
                            wsDash.Cells(rA, 5).Value = "資料異常"
                            wsDash.Cells(rA, 6).Value = "資料異常"
                        End If

                    Case "RSI"
                        wsDash.Cells(rA, 7).Value = ExtractNumAfter(bp, "K=")
                        wsDash.Cells(rA, 8).Value = ExtractNumAfter(bp, "下=")
                        wsDash.Cells(rA, 9).Value = ExtractNumAfter(bp, "上=")

                    Case "KD"
                        If ValidateRatio(bpRaw, 3, cleanS) Then
                            wsDash.Cells(rA, 10).NumberFormat = "@"
                            wsDash.Cells(rA, 10).Value = cleanS
                        Else
                            wsDash.Cells(rA, 10).Value = "資料異常"
                        End If

                    Case "PSY"
                        wsDash.Cells(rA, 11).Value = Val(bp)
                        bStart = InStr(bp, "(")
                        bEnd = InStr(bp, ")")
                        If bStart > 0 And bEnd > bStart Then
                            wsDash.Cells(rA, 12).Value = ExtractNumAfter(Mid(bp, bStart, bEnd - bStart + 1), "上下")
                        End If

                    Case "WR"
                        wsDash.Cells(rA, 13).Value = Val(bp)

                    Case "MTM"
                        wsDash.Cells(rA, 14).Value = Val(bp)

                    Case "MACD"
                        If ValidateRatio(bpRaw, 3, cleanS) Then
                            wsDash.Cells(rA, 15).NumberFormat = "@"
                            wsDash.Cells(rA, 15).Value = cleanS
                        Else
                            wsDash.Cells(rA, 15).Value = "資料異常"
                        End If

                    Case "BOLL"
                        If ValidateRatio(bpRaw, 2, cleanS) Then
                            wsDash.Cells(rA, 16).NumberFormat = "@"
                            wsDash.Cells(rA, 16).Value = cleanS
                        Else
                            wsDash.Cells(rA, 16).Value = "資料異常"
                        End If

                    Case "CCI"
                        wsDash.Cells(rA, 17).Value = Val(bp)

                    Case "BIAS"
                        wsDash.Cells(rA, 18).Value = Val(bp)

                    Case "KELTNER"
                        If ValidateRatio(bpRaw, 2, cleanS) Then
                            wsDash.Cells(rA, 19).NumberFormat = "@"
                            wsDash.Cells(rA, 19).Value = cleanS
                        Else
                            wsDash.Cells(rA, 19).Value = "資料異常"
                        End If
                End Select

                If IsNumeric(winPct) And Not IsEmpty(winPct) Then
                    sumWin = sumWin + CDbl(winPct)
                    cntInd = cntInd + 1
                End If
                If IsNumeric(alphaV) And Not IsEmpty(alphaV) Then sumAlpha = sumAlpha + CDbl(alphaV)
            End If
        Next r

        If cntInd > 0 Then
            wsDash.Cells(rA, 20).Value = Format(sumWin / cntInd, "0.0") & "% / " & Format(sumAlpha / cntInd, "0.000")
        End If

        wsDash.Cells(rA, 21).NumberFormat = "m/d/yyyy hh:mm"
        wsDash.Cells(rA, 21).Value = runTime

        rB = 15 + pIdx
        rC = 21 + pIdx
        wsDash.Range(wsDash.Cells(rB, 1), wsDash.Cells(rB, 13)).ClearContents
        wsDash.Range(wsDash.Cells(rC, 1), wsDash.Cells(rC, 14)).ClearContents
        wsDash.Cells(rC, 1).Value = period

        For r = 2 To lastRowS
            If Trim(CStr(wsStatus.Cells(r, 1).Value)) = symbol And Trim(CStr(wsStatus.Cells(r, 2).Value)) = period Then
                statusHits = statusHits + 1
                longV = CLng(Val(wsStatus.Cells(r, 5).Value))
                shortV = CLng(Val(wsStatus.Cells(r, 6).Value))

                wsDash.Cells(rB, 1).Value = symbol
                wsDash.Cells(rB, 2).Value = period
                wsDash.Cells(rB, 3).NumberFormat = "yyyy-mm-dd hh:mm"
                wsDash.Cells(rB, 3).Value = wsStatus.Cells(r, 3).Value
                wsDash.Cells(rB, 4).NumberFormat = "0.00000"
                wsDash.Cells(rB, 4).Value = wsStatus.Cells(r, 4).Value
                wsDash.Cells(rB, 5).Value = longV
                wsDash.Cells(rB, 6).Value = shortV
                wsDash.Cells(rB, 7).Value = wsStatus.Cells(r, 7).Value
                wsDash.Cells(rB, 8).Value = weights(pIdx)

                If longV >= 9 Then
                    sig = "強多共振"
                ElseIf shortV >= 9 Then
                    sig = "強空共振"
                ElseIf longV > shortV Then
                    sig = "偏多"
                ElseIf shortV > longV Then
                    sig = "偏空"
                Else
                    sig = "震盪"
                End If
                wsDash.Cells(rB, 9).Value = sig

                lastClose = Val(CStr(wsStatus.Cells(r, 4).Value))
                If todayOpen > 0 Then
                    wsDash.Cells(rB, 10).NumberFormat = wsDash.Cells(rB, 4).NumberFormat
                    wsDash.Cells(rB, 10).Value = todayOpen
                    If lastClose > 0 Then
                        wsDash.Cells(rB, 11).NumberFormat = "0.000%"
                        wsDash.Cells(rB, 11).Value = (lastClose - todayOpen) / todayOpen
                    End If
                Else
                    wsDash.Cells(rB, 10).Value = "無資料"
                End If
                wsDash.Cells(rB, 12).Value = longV - shortV    ' 多票減空票，抵銷後的淨分
                wsDash.Cells(rB, 13).Value = freshTxt

                Dim kI As Long
                For kI = 0 To 10   ' 狀態總表第 9~19 欄 = MA,RSI,KD,PSY,WR,MTM,MACD,BOLL,CCI,BIAS,KELTNER
                    wsDash.Cells(rC, 2 + kI).Value = wsStatus.Cells(r, 9 + kI).Value
                    If wsDash.Cells(rC, 2 + kI).Value = "多" Then
                        wsDash.Cells(rC, 2 + kI).Font.Color = RGB(0, 97, 0)
                    ElseIf wsDash.Cells(rC, 2 + kI).Value = "空" Then
                        wsDash.Cells(rC, 2 + kI).Font.Color = RGB(156, 0, 6)
                    End If
                Next kI
                wsDash.Cells(rC, 13).Value = longV
                wsDash.Cells(rC, 14).Value = shortV
                Exit For
            End If
        Next r
    Next pIdx

    wsDash.Columns("A:V").AutoFit
    wsDash.Columns("A").ColumnWidth = DASH_COL_A_WIDTH

    AddReport "【儀表板】" & symbol & "：狀態 " & statusHits & "/5 個週期，參數 " & paramHits & " 筆" & _
              IIf(paramHits = 0, "（多商品參數優化 沒有 " & symbol & " 的資料，所以 C~T 欄會空白）", "")

Finalize:
    Application.ScreenUpdating = True
    If Not gQuiet Then ShowReport "儀表板更新結果"
    Exit Sub

ErrHandler:
    AddReport "【儀表板】錯誤：" & Err.Description
    Resume Finalize
End Sub

Private Function ExtractNumAfter(s As String, marker As String) As Double
    Dim p As Long: p = InStr(s, marker)
    If p = 0 Then
        ExtractNumAfter = 0
        Exit Function
    End If

    Dim rest As String: rest = Mid(s, p + Len(marker))
    Dim numStr As String, i As Long, ch As String
    numStr = ""
    For i = 1 To Len(rest)
        ch = Mid(rest, i, 1)
        If (ch >= "0" And ch <= "9") Or ch = "." Or ch = "-" Then
            numStr = numStr & ch
        Else
            If Len(numStr) > 0 Then Exit For
        End If
    Next i
    ExtractNumAfter = Val(numStr)
End Function

Private Function ValidateRatio(rawValue As Variant, expectedParts As Integer, ByRef cleanStr As String) As Boolean
    cleanStr = Trim(CStr(rawValue))

    If TypeName(rawValue) = "Date" Then
        ValidateRatio = False
        Exit Function
    End If

    If InStr(cleanStr, "/") = 0 Then
        ValidateRatio = False
        Exit Function
    End If

    Dim parts() As String: parts = Split(cleanStr, "/")
    If (UBound(parts) - LBound(parts) + 1) <> expectedParts Then
        ValidateRatio = False
        Exit Function
    End If

    Dim i As Long, v As Double
    For i = LBound(parts) To UBound(parts)
        If Not IsNumeric(Trim(parts(i))) Then
            ValidateRatio = False
            Exit Function
        End If
        v = Val(Trim(parts(i)))
        If v > RATIO_MAX_VALUE Or v < 0 Then
            ValidateRatio = False
            Exit Function
        End If
    Next i

    ValidateRatio = True
End Function

' =============================================
' 儀表板 B5 下拉換商品 → 自動更新儀表板（不跑 Python、不跳視窗）
' 開檔時由 Auto_Open 掛上（同時載入最近一次的資料）；按「更新關卡」按鈕時也會再掛一次
' =============================================
Public Sub Auto_Open()
    ' 開檔就把 update_output 裡最近一次的 CSV 讀進來（不跑 Python，幾秒內完成），工作表不會是空的
    On Error Resume Next
    gReport = ""
    gQuiet = True
    Application.ScreenUpdating = False
    Call ImportAllCsv
    Call Update關卡
    Call RefreshDashboard
    Application.ScreenUpdating = True
    gQuiet = False
    gReport = ""
    Call 掛上換商品監聽
End Sub

Private Sub 掛上換商品監聽()
    On Error Resume Next
    Set gHook = New clsDash
    Set gHook.ws = Application.ThisWorkbook.Worksheets("儀表板總表")
End Sub

Public Sub 切換商品()
    gReport = ""
    gQuiet = True
    Call RefreshDashboard
    gQuiet = False
    gReport = ""
End Sub
