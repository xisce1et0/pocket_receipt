#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <onnxruntime_c_api.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

struct SessionHolder {
  OrtSession* session = nullptr;
  std::string model_path;
  std::string input_name;
  std::string output_name;
};

std::mutex g_mutex;
const OrtApi* g_ort = nullptr;
OrtEnv* g_env = nullptr;
SessionHolder g_det;
SessionHolder g_rec;
SessionHolder g_clf;
std::string g_last_error;

void SetError(const std::string& msg) { g_last_error = msg; }

bool CheckStatus(OrtStatus* status) {
  if (status == nullptr) return true;
  const char* msg = g_ort->GetErrorMessage(status);
  SetError(msg != nullptr ? msg : "Unknown ONNX Runtime error");
  g_ort->ReleaseStatus(status);
  return false;
}

bool EnsureOrtEnv() {
  if (g_ort == nullptr) {
    const OrtApiBase* base = OrtGetApiBase();
    if (base == nullptr) {
      SetError("OrtGetApiBase returned null");
      return false;
    }
    g_ort = base->GetApi(ORT_API_VERSION);
    if (g_ort == nullptr) {
      SetError("ONNX Runtime API version mismatch");
      return false;
    }
  }
  if (g_env == nullptr) {
    if (!CheckStatus(
            g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "pocket_ocr", &g_env))) {
      return false;
    }
  }
  return true;
}

std::wstring Utf8ToWide(const char* utf8) {
  if (utf8 == nullptr || utf8[0] == '\0') return std::wstring();
  int len = static_cast<int>(std::strlen(utf8));
  int needed = MultiByteToWideChar(CP_UTF8, 0, utf8, len, nullptr, 0);
  if (needed <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8, len, out.data(), needed);
  return out;
}

void ReleaseHolder(SessionHolder& holder) {
  if (holder.session != nullptr && g_ort != nullptr) {
    g_ort->ReleaseSession(holder.session);
    holder.session = nullptr;
  }
  holder.model_path.clear();
  holder.input_name.clear();
  holder.output_name.clear();
}

bool LoadSession(SessionHolder& holder, const char* path_utf8, int32_t threads,
                 bool query_single_io) {
  if (path_utf8 == nullptr || path_utf8[0] == '\0') {
    SetError("Empty model path");
    return false;
  }
  std::string path_str(path_utf8);
  if (holder.session != nullptr && holder.model_path == path_str) {
    return true;
  }

  ReleaseHolder(holder);

  OrtSessionOptions* opts = nullptr;
  if (!CheckStatus(g_ort->CreateSessionOptions(&opts))) return false;

  int32_t safe_threads = threads > 0 ? threads : 4;
  if (!CheckStatus(g_ort->SetIntraOpNumThreads(opts, safe_threads))) {
    g_ort->ReleaseSessionOptions(opts);
    return false;
  }
  if (!CheckStatus(g_ort->SetSessionGraphOptimizationLevel(
          opts, ORT_ENABLE_EXTENDED))) {
    g_ort->ReleaseSessionOptions(opts);
    return false;
  }

  std::wstring wide_path = Utf8ToWide(path_utf8);
  OrtSession* session = nullptr;
  bool ok = CheckStatus(
      g_ort->CreateSession(g_env, wide_path.c_str(), opts, &session));
  g_ort->ReleaseSessionOptions(opts);
  if (!ok) return false;

  if (!query_single_io) {
    holder.session = session;
    holder.model_path = path_str;
    return true;
  }

  OrtAllocator* allocator = nullptr;
  if (!CheckStatus(g_ort->GetAllocatorWithDefaultOptions(&allocator))) {
    g_ort->ReleaseSession(session);
    return false;
  }

  char* in_name = nullptr;
  char* out_name = nullptr;
  ok = CheckStatus(g_ort->SessionGetInputName(session, 0, allocator, &in_name));
  if (ok) {
    ok = CheckStatus(
        g_ort->SessionGetOutputName(session, 0, allocator, &out_name));
  }

  if (ok && in_name != nullptr && out_name != nullptr) {
    holder.session = session;
    holder.model_path = path_str;
    holder.input_name = in_name;
    holder.output_name = out_name;
  } else {
    g_ort->ReleaseSession(session);
    ok = false;
  }

  if (in_name != nullptr) g_ort->AllocatorFree(allocator, in_name);
  if (out_name != nullptr) g_ort->AllocatorFree(allocator, out_name);
  return ok;
}

bool CopyFloatTensor(OrtValue* tensor, float** out_buf, int64_t* out_len) {
  OrtTensorTypeAndShapeInfo* type_info = nullptr;
  if (!CheckStatus(g_ort->GetTensorTypeAndShape(tensor, &type_info))) {
    return false;
  }

  size_t elem_count = 0;
  bool ok = CheckStatus(
      g_ort->GetTensorShapeElementCount(type_info, &elem_count));
  g_ort->ReleaseTensorTypeAndShapeInfo(type_info);
  if (!ok) return false;

  float* raw_out = nullptr;
  if (!CheckStatus(g_ort->GetTensorMutableData(
          tensor, reinterpret_cast<void**>(&raw_out)))) {
    return false;
  }

  float* buf = static_cast<float*>(std::malloc(elem_count * sizeof(float)));
  if (buf == nullptr) {
    SetError("Out of memory allocating ONNX float output buffer");
    return false;
  }
  if (elem_count > 0) {
    std::memcpy(buf, raw_out, elem_count * sizeof(float));
  }
  *out_buf = buf;
  *out_len = static_cast<int64_t>(elem_count);
  return true;
}

}  // namespace

extern "C" {

__declspec(dllexport) void* ort_alloc(int64_t size) {
  if (size <= 0) return nullptr;
  return std::malloc(static_cast<size_t>(size));
}

__declspec(dllexport) void ort_free(void* ptr) {
  if (ptr != nullptr) std::free(ptr);
}

__declspec(dllexport) const char* ort_get_last_error() {
  return g_last_error.c_str();
}

__declspec(dllexport) int32_t ort_init_ocr(const char* det_path_utf8,
                                           const char* rec_path_utf8,
                                           int32_t threads) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_last_error.clear();

  if (!EnsureOrtEnv()) return 1;
  if (!LoadSession(g_det, det_path_utf8, threads, true)) return 4;
  if (!LoadSession(g_rec, rec_path_utf8, threads, true)) return 5;
  return 0;
}

__declspec(dllexport) int32_t ort_init_clf(const char* clf_path_utf8,
                                           int32_t threads) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_last_error.clear();

  if (!EnsureOrtEnv()) return 1;
  if (!LoadSession(g_clf, clf_path_utf8, threads, false)) return 2;
  return 0;
}

__declspec(dllexport) int32_t ort_run_ocr(
    int32_t is_rec, const float* input_data, int64_t input_len,
    const int64_t* input_shape, int32_t shape_len, float** out_data,
    int64_t* out_len, int64_t* out_shape, int32_t* out_shape_len) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_last_error.clear();

  if (g_ort == nullptr || input_data == nullptr || input_shape == nullptr ||
      out_data == nullptr || out_len == nullptr || out_shape == nullptr ||
      out_shape_len == nullptr || input_len <= 0 || shape_len <= 0) {
    SetError("Invalid arguments to ort_run_ocr");
    return 1;
  }

  SessionHolder& holder = (is_rec != 0) ? g_rec : g_det;
  if (holder.session == nullptr) {
    SetError("OCR session is not initialized");
    return 2;
  }

  OrtMemoryInfo* mem_info = nullptr;
  OrtValue* input_tensor = nullptr;
  OrtValue* output_tensor = nullptr;
  OrtTensorTypeAndShapeInfo* type_info = nullptr;
  int32_t rc = 0;

  do {
    if (!CheckStatus(g_ort->CreateCpuMemoryInfo(
            OrtArenaAllocator, OrtMemTypeDefault, &mem_info))) {
      rc = 3;
      break;
    }

    if (!CheckStatus(g_ort->CreateTensorWithDataAsOrtValue(
            mem_info, const_cast<float*>(input_data),
            static_cast<size_t>(input_len) * sizeof(float), input_shape,
            static_cast<size_t>(shape_len), ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
            &input_tensor))) {
      rc = 4;
      break;
    }

    const char* in_name = holder.input_name.c_str();
    const char* out_name = holder.output_name.c_str();
    const OrtValue* in_val = input_tensor;
    if (!CheckStatus(g_ort->Run(holder.session, nullptr, &in_name, &in_val, 1,
                                &out_name, 1, &output_tensor))) {
      rc = 5;
      break;
    }

    if (!CheckStatus(g_ort->GetTensorTypeAndShape(output_tensor, &type_info))) {
      rc = 6;
      break;
    }

    size_t dims_count = 0;
    if (!CheckStatus(g_ort->GetDimensionsCount(type_info, &dims_count))) {
      rc = 7;
      break;
    }

    std::vector<int64_t> dims(dims_count, 0);
    if (dims_count > 0 &&
        !CheckStatus(
            g_ort->GetDimensions(type_info, dims.data(), dims_count))) {
      rc = 8;
      break;
    }

    size_t elem_count = 0;
    if (!CheckStatus(
            g_ort->GetTensorShapeElementCount(type_info, &elem_count))) {
      rc = 9;
      break;
    }

    float* raw_out = nullptr;
    if (!CheckStatus(g_ort->GetTensorMutableData(
            output_tensor, reinterpret_cast<void**>(&raw_out)))) {
      rc = 10;
      break;
    }

    float* buf = static_cast<float*>(std::malloc(elem_count * sizeof(float)));
    if (buf == nullptr) {
      SetError("Out of memory allocating ONNX output buffer");
      rc = 11;
      break;
    }
    if (elem_count > 0) {
      std::memcpy(buf, raw_out, elem_count * sizeof(float));
    }

    size_t copy_dims = std::min<size_t>(dims_count, 4);
    for (size_t i = 0; i < copy_dims; ++i) {
      out_shape[i] = dims[i];
    }
    *out_shape_len = static_cast<int32_t>(copy_dims);
    *out_data = buf;
    *out_len = static_cast<int64_t>(elem_count);
  } while (false);

  if (type_info != nullptr) g_ort->ReleaseTensorTypeAndShapeInfo(type_info);
  if (output_tensor != nullptr) g_ort->ReleaseValue(output_tensor);
  if (input_tensor != nullptr) g_ort->ReleaseValue(input_tensor);
  if (mem_info != nullptr) g_ort->ReleaseMemoryInfo(mem_info);
  return rc;
}

__declspec(dllexport) int32_t ort_run_clf(
    const int64_t* input_ids, const int64_t* attention_mask, int32_t batch_size,
    int32_t seq_len, float** out_role_logits, int64_t* out_role_len,
    float** out_cat_logits, int64_t* out_cat_len) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_last_error.clear();

  if (g_ort == nullptr || input_ids == nullptr || attention_mask == nullptr ||
      out_role_logits == nullptr || out_role_len == nullptr ||
      out_cat_logits == nullptr || out_cat_len == nullptr || batch_size <= 0 ||
      seq_len <= 0) {
    SetError("Invalid arguments to ort_run_clf");
    return 1;
  }

  if (g_clf.session == nullptr) {
    SetError("Classifier session is not initialized");
    return 2;
  }

  OrtMemoryInfo* mem_info = nullptr;
  OrtValue* ids_tensor = nullptr;
  OrtValue* mask_tensor = nullptr;
  OrtValue* out_tensors[2] = {nullptr, nullptr};
  int32_t rc = 0;

  *out_role_logits = nullptr;
  *out_role_len = 0;
  *out_cat_logits = nullptr;
  *out_cat_len = 0;

  do {
    if (!CheckStatus(g_ort->CreateCpuMemoryInfo(
            OrtArenaAllocator, OrtMemTypeDefault, &mem_info))) {
      rc = 3;
      break;
    }

    int64_t shape[2] = {static_cast<int64_t>(batch_size),
                        static_cast<int64_t>(seq_len)};
    size_t elem_count =
        static_cast<size_t>(batch_size) * static_cast<size_t>(seq_len);
    size_t byte_len = elem_count * sizeof(int64_t);

    if (!CheckStatus(g_ort->CreateTensorWithDataAsOrtValue(
            mem_info, const_cast<int64_t*>(input_ids), byte_len, shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &ids_tensor))) {
      rc = 4;
      break;
    }

    if (!CheckStatus(g_ort->CreateTensorWithDataAsOrtValue(
            mem_info, const_cast<int64_t*>(attention_mask), byte_len, shape, 2,
            ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &mask_tensor))) {
      rc = 5;
      break;
    }

    const char* in_names[2] = {"input_ids", "attention_mask"};
    const OrtValue* in_vals[2] = {ids_tensor, mask_tensor};
    const char* out_names[2] = {"role_logits", "cat_logits"};

    if (!CheckStatus(g_ort->Run(g_clf.session, nullptr, in_names, in_vals, 2,
                                out_names, 2, out_tensors))) {
      rc = 6;
      break;
    }

    if (!CopyFloatTensor(out_tensors[0], out_role_logits, out_role_len)) {
      rc = 7;
      break;
    }
    if (!CopyFloatTensor(out_tensors[1], out_cat_logits, out_cat_len)) {
      if (*out_role_logits != nullptr) {
        std::free(*out_role_logits);
        *out_role_logits = nullptr;
        *out_role_len = 0;
      }
      rc = 8;
      break;
    }
  } while (false);

  if (out_tensors[0] != nullptr) g_ort->ReleaseValue(out_tensors[0]);
  if (out_tensors[1] != nullptr) g_ort->ReleaseValue(out_tensors[1]);
  if (mask_tensor != nullptr) g_ort->ReleaseValue(mask_tensor);
  if (ids_tensor != nullptr) g_ort->ReleaseValue(ids_tensor);
  if (mem_info != nullptr) g_ort->ReleaseMemoryInfo(mem_info);
  return rc;
}

}  // extern "C"