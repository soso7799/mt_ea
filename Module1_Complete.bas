'====================================================================
' Module1 完整內容 —— 這一整份請整段取代 Gordon_FTMO_Data_Console
' 活頁簿裡 Module1 目前的所有程式碼（先全選 Module1 內容刪除，
' 再把這份整段貼進去），一次到位，不用再手動拼湊。
'
' 內含 3 個程序：
'   1. GDH_BatchExportSelected —— 批次匯出（支援增量 --since）
'   2. GDH_UpdateEverything    —— 一鍵按鈕：匯出+合併+更新CSV+刷新畫面
'   3. GDH_Quote               —— GDH_UpdateEverything 專用的小工具函式
' 三個名字都不重複，不會有 Ambiguous name 的問題。
'====================================================================

'====================================================================
' 批次匯出「市場清單」裡打勾的商品(C欄) × 打勾的週期(D欄)，
' 每個組合都匯出一份CSV到 D:\整合計畫\整理後\ExportCSV\
'
' 用法：
'   1. 「市場清單」A欄旁的C欄，想匯出的商品打 X
'   2. 「市場清單」B欄旁的D欄，想匯出的週期打 X
'   3. 執行本巨集(建議做成按鈕)，會匯出「所有勾選商品」x「所有勾選週期」的全部組合
'   4. 週期清單裡如果勾選「ALL」，會自動展開成 D1/H4/H1/M15 這4個
'      (量化分析引擎目前只支援這4個週期，其餘週期只會單純匯出CSV，不會進優化分析)
'
' ⚠️ 這版本改成支援增量更新：
'   - 匯出前會先讀 D:\整合計畫\整理後\ExportCSV\merged\_last_bar_state.csv
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
    folderPath = "D:\整合計畫\整理後\ExportCSV\"
    If Dir$(folderPath, vbDirectory) = "" Then
        If Dir$("D:\整合計畫\整理後", vbDirectory) = "" Then MkDir "D:\整合計畫\整理後"
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
    scriptFile = "D:\整合計畫\整理後\gordon_mt5_incremental.py"
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
            outputCsv = "D:\整合計畫\整理後\mt_export_" & tfName & ".csv"

            Dim command As String
            If isIncremental Then
                command = GDH_Quote(pythonExe) & " " & GDH_Quote(scriptFile) & _
                    " --db " & GDH_Quote("D:\整合計畫\整理後") & _
                    " --symbol " & GDH_Quote(symbolStr) & _
                    " --timeframe " & GDH_Quote(tfName) & _
                    " --since " & GDH_Quote(sinceValue) & _
                    " --output " & GDH_Quote(outputCsv)
                incrementalCount = incrementalCount + 1
            Else
                command = GDH_Quote(pythonExe) & " " & GDH_Quote(scriptFile) & _
                    " --db " & GDH_Quote("D:\整合計畫\整理後") & _
                    " --symbol " & GDH_Quote(symbolStr) & _
                    " --timeframe " & GDH_Quote(tfName) & _
                    " --amount " & CStr(amount) & _
                    " --unit " & unitCode & _
                    " --output " & GDH_Quote(outputCsv)
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


'====================================================================
' GDH_UpdateEverything
' 一鍵按鈕巨集：串起完整的資料更新流程，一次做完 4 件事：
'   1. 呼叫上面的 GDH_BatchExportSelected，匯出「市場清單」裡打勾的
'      商品(C欄) x 週期(D欄)組合
'   2. 執行 merge_export_csv.py --delete-source --yes：
'      把 D:\整合計畫\整理後\ExportCSV 底下所有商品/週期的快照合併進 merged
'      資料夾，合併成功的舊快照會被刪除釋放硬碟空間（merged資料夾本身
'      跟合併結果絕對不會被刪）
'   3. 執行 update_all_data.py：從 merged 資料夾產生
'      today_open.csv / session_levels.csv 給 Excel 儀表板讀
'   4. 呼叫既有的 Update關卡 + RefreshDashboard，把「關卡」跟
'      「儀表板總表」畫面刷新成最新資料
'
' 使用前置作業（只要做一次）：
'   - 把 merge_export_csv.py 放到 D:\整合計畫\整理後\merge_export_csv.py
'     （找不到的話會退而求其次找 ThisWorkbook.Path 底下有沒有）
'   - update_all_data.py 沿用 Module1 既有設定，放在 D:\整合計畫\整理後\update_all_data.py
'
' 安裝方式：回工作表，插入→按鈕（表單控制項），指派巨集選 GDH_UpdateEverything
'====================================================================

Public Sub GDH_UpdateEverything()
    Dim t0 As Single: t0 = Timer

    ' ---------- 步驟1：批次匯出（沿用你原本的巨集，含它自己的確認視窗）----------
    Application.StatusBar = "步驟 1/4：批次匯出中..."
    DoEvents
    Call GDH_BatchExportSelected

    ' ---------- 步驟2：合併ExportCSV快照 + 清理舊檔 ----------
    Application.StatusBar = "步驟 2/4：合併資料庫中..."
    DoEvents

    Dim pythonExe As String
    pythonExe = Environ$("LOCALAPPDATA") & "\hermes\hermes-agent\venv\Scripts\python.exe"
    If Dir$(pythonExe) = "" Then
        MsgBox "找不到 Python 執行檔：" & pythonExe, vbCritical, "環境錯誤"
        Application.StatusBar = False
        Exit Sub
    End If

    Dim mergeScript As String
    mergeScript = "D:\整合計畫\整理後\merge_export_csv.py"
    If Dir$(mergeScript) = "" Then mergeScript = ThisWorkbook.Path & "\merge_export_csv.py"
    If Dir$(mergeScript) = "" Then
        MsgBox "找不到 merge_export_csv.py，請先放到 D:\整合計畫\整理後\ 底下。", vbCritical, "環境錯誤"
        Application.StatusBar = False
        Exit Sub
    End If

    Dim shell As Object
    Set shell = CreateObject("WScript.Shell")

    Dim mergeCmd As String
    mergeCmd = GDH_Quote(pythonExe) & " " & GDH_Quote(mergeScript) & " --delete-source --yes"
    Dim mergeExit As Long
    mergeExit = shell.Run(mergeCmd, 0, True)
    If mergeExit <> 0 Then
        MsgBox "合併腳本執行失敗，ExitCode=" & mergeExit & vbCrLf & _
               "（此步驟失敗不影響已匯出的原始資料，可稍後手動重跑 merge_export_csv.py 排查）", _
               vbExclamation, "步驟2失敗"
    End If

    ' ---------- 步驟3：產生儀表板用的CSV ----------
    Application.StatusBar = "步驟 3/4：更新儀表板資料中..."
    DoEvents

    Dim updateScript As String
    updateScript = "D:\整合計畫\整理後\update_all_data.py"
    If Dir$(updateScript) = "" Then
        MsgBox "找不到 update_all_data.py：" & updateScript, vbCritical, "環境錯誤"
        Application.StatusBar = False
        Exit Sub
    End If

    Dim updateCmd As String
    updateCmd = GDH_Quote(pythonExe) & " " & GDH_Quote(updateScript)
    Dim updateExit As Long
    updateExit = shell.Run(updateCmd, 0, True)
    If updateExit <> 0 Then
        MsgBox "update_all_data.py 執行失敗，ExitCode=" & updateExit, vbExclamation, "步驟3失敗"
        Application.StatusBar = False
        Exit Sub
    End If

    ' ---------- 步驟4：刷新畫面 ----------
    ' Update關卡 / RefreshDashboard 是活在「另一個」活頁簿裡（含「關卡」「儀表板
    ' 總表」分頁的那個資料儀表板檔），不是這個 Gordon_FTMO_Data_Console 活頁簿，
    ' 所以不能直接 Call，要用 Application.Run 指定活頁簿名稱去呼叫。
    ' 這裡用「掃描目前所有開著的活頁簿，找出有『儀表板總表』分頁的那個」，
    ' 不寫死檔名，避免檔名帶版本尾巴（例如 "(1)"）時對不上。
    Application.StatusBar = "步驟 4/4：刷新畫面中..."
    DoEvents

    Dim wbDash As Workbook, wbTest As Workbook
    Dim shTest As Worksheet, hasSheet As Boolean
    For Each wbTest In Application.Workbooks
        hasSheet = False
        On Error Resume Next
        Set shTest = wbTest.Sheets("儀表板總表")
        hasSheet = Not shTest Is Nothing
        On Error GoTo 0
        Set shTest = Nothing
        If hasSheet Then
            Set wbDash = wbTest
            Exit For
        End If
    Next wbTest

    If wbDash Is Nothing Then
        MsgBox "找不到含有「儀表板總表」分頁的活頁簿，請確認那個資料儀表板檔案有打開。" & vbCrLf & _
               "（前3步已經完成，只差這步刷新畫面沒做，資料本身是新的）", _
               vbExclamation, "步驟4找不到儀表板活頁簿"
    Else
        Application.ScreenUpdating = False
        Application.Run "'" & wbDash.Name & "'!Update關卡"
        wbDash.Sheets("儀表板總表").Activate
        Application.Run "'" & wbDash.Name & "'!RefreshDashboard"
        Application.ScreenUpdating = True
    End If

    Application.StatusBar = False
    MsgBox "全部更新完成！" & vbCrLf & _
           "（含批次匯出 + 合併資料庫 + 清理舊快照 + 刷新畫面）" & vbCrLf & vbCrLf & _
           "耗時：" & Format(Timer - t0, "0.0") & " 秒" & vbCrLf & Now, _
           vbInformation, "GDH_UpdateEverything 完成"
End Sub


' GDH_BatchExportSelected 跟 GDH_UpdateEverything 共用的小工具函式，
' 只保留這一份，不要再重複貼。
Private Function GDH_Quote(ByVal value As String) As String
    GDH_Quote = Chr$(34) & value & Chr$(34)
End Function
