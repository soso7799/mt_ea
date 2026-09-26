//+------------------------------------------------------------------+
//|  MLFilter.mqh                                                    |
//|  ML 第3階段：載入 ml/train.py 匯出的 ONNX 模型，                   |
//|  依信號特徵算出「先到 TP」的機率。                                 |
//|  模型位置：Common\Files\<路徑>（setup_drives.bat 連結到             |
//|  執行程式碟 releases\models）。                                    |
//|  載入失敗或推論失敗時 Ready()/Predict() 回報失敗，EA 退回不過濾。  |
//+------------------------------------------------------------------+
#ifndef MLFILTER_MQH
#define MLFILTER_MQH

class CMLFilter
{
private:
   long m_handle;
   int  m_nf;

public:
   CMLFilter() : m_handle(INVALID_HANDLE), m_nf(0) {}
   ~CMLFilter() { Release(); }

   bool Ready() { return m_handle != INVALID_HANDLE; }

   bool Init(string path, int nFeatures)
   {
      Release();
      m_nf = nFeatures;

      m_handle = OnnxCreate(path, ONNX_COMMON_FOLDER);
      if(m_handle == INVALID_HANDLE)
      {
         PrintFormat("⚠️ MLFilter: 無法載入模型 Common\\Files\\%s (err=%d)，不使用 ML 過濾", path, GetLastError());
         return false;
      }

      if(OnnxGetInputCount(m_handle) != 1 || OnnxGetOutputCount(m_handle) != 2)
      {
         PrintFormat("⚠️ MLFilter: 模型格式不符（輸入 %I64d、輸出 %I64d，應為 1 與 2），不使用 ML 過濾",
                     OnnxGetInputCount(m_handle), OnnxGetOutputCount(m_handle));
         Release();
         return false;
      }

      OnnxTypeInfo info;
      if(OnnxGetInputTypeInfo(m_handle, 0, info))
      {
         int dims = ArraySize(info.tensor.dimensions);
         if(dims != 2 || info.tensor.dimensions[1] != m_nf)
         {
            PrintFormat("⚠️ MLFilter: 模型特徵數 %I64d 與 EA 的 %d 不符，請重新訓練，不使用 ML 過濾",
                        dims == 2 ? info.tensor.dimensions[1] : -1, m_nf);
            Release();
            return false;
         }
      }

      ulong inShape[]   = {1, (ulong)m_nf};
      ulong labelShape[] = {1};
      ulong probShape[]  = {1, 2};
      if(!OnnxSetInputShape(m_handle, 0, inShape) ||
         !OnnxSetOutputShape(m_handle, 0, labelShape) ||
         !OnnxSetOutputShape(m_handle, 1, probShape))
      {
         PrintFormat("⚠️ MLFilter: 設定模型輸入輸出形狀失敗 (err=%d)，不使用 ML 過濾", GetLastError());
         Release();
         return false;
      }

      PrintFormat("MLFilter: 已載入模型 Common\\Files\\%s（%d 個特徵）", path, m_nf);
      return true;
   }

   // 回傳 P(先到 TP)，失敗回傳 -1
   double Predict(const double &f[])
   {
      if(!Ready() || ArraySize(f) != m_nf) return -1;

      matrixf x(1, m_nf);
      for(int i = 0; i < m_nf; i++) x[0][i] = (float)f[i];

      vectorl label(1);
      matrixf prob(1, 2);
      if(!OnnxRun(m_handle, ONNX_NO_CONVERSION, x, label, prob))
      {
         PrintFormat("⚠️ MLFilter: 推論失敗 (err=%d)", GetLastError());
         return -1;
      }
      return (double)prob[0][1];
   }

   void Release()
   {
      if(m_handle != INVALID_HANDLE)
      {
         OnnxRelease(m_handle);
         m_handle = INVALID_HANDLE;
      }
   }
};

#endif
