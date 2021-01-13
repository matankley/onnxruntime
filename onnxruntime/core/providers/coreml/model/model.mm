// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include <cstdint>
#include <unordered_map>
#include <vector>

#include "model.h"
#include "core/common/common.h"
#include "core/graph/onnx_protobuf.h"

#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>

#define API_AVAILABLE_OS_VERSIONS API_AVAILABLE(macos(10.15), ios(13))
#define HAS_VALID_OS_VERSION @available(macOS 10.15, iOS 13, *)

// Model input for CoreML model
// All the input onnx tensors values will be converted to MLMultiArray(s)
@interface OnnxTensorFeatureProvider : NSObject <MLFeatureProvider> {
  const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>* inputs_;
  NSSet* featureNames_;
}

- (instancetype)initWithInputs:(const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>&)inputs;
- (MLFeatureValue*)featureValueForName:(NSString*)featureName API_AVAILABLE_OS_VERSIONS;
- (NSSet<NSString*>*)featureNames;

@end

@interface CoreMLExecution : NSObject {
  NSString* coreml_model_path_;
  NSString* compiled_model_path_;
}

- (instancetype)initWithPath:(const std::string&)path;
- (void)cleanup;
- (void)dealloc;
- (onnxruntime::common::Status)loadModel API_AVAILABLE_OS_VERSIONS;
- (onnxruntime::common::Status)
    predict:(const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>&)inputs
    outputs:(const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>&)outputs
    API_AVAILABLE_OS_VERSIONS;

@property MLModel* model API_AVAILABLE_OS_VERSIONS;

@end

@implementation OnnxTensorFeatureProvider

- (instancetype)initWithInputs:(const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>&)inputs {
  self = [super init];
  inputs_ = &inputs;
  return self;
}

- (nonnull NSSet<NSString*>*)featureNames {
  if (featureNames_ == nil) {
    NSMutableArray* names = [[NSMutableArray alloc] init];
    for (const auto& input : *inputs_) {
      [names addObject:[NSString stringWithCString:input.first.c_str()
                                          encoding:[NSString defaultCStringEncoding]]];
    }

    featureNames_ = [NSSet setWithArray:names];
  }

  return featureNames_;
}

- (nullable MLFeatureValue*)featureValueForName:(nonnull NSString*)featureName {
  auto it = inputs_->find([featureName cStringUsingEncoding:NSUTF8StringEncoding]);
  if (it != inputs_->end()) {
    auto& input = it->second;
    NSMutableArray* shape = [[NSMutableArray alloc] init];
    for (const auto dim : input.shape) {
      [shape addObject:[NSNumber numberWithLongLong:dim]];
    }

    NSMutableArray* strides = [[NSMutableArray alloc] init];
    int64_t stride = 1;
    for (int i = static_cast<int>(input.shape.size()) - 1; i >= 0; i--) {
      [strides insertObject:[NSNumber numberWithLongLong:stride]
                    atIndex:0];

      stride *= input.shape[i];
    }

    MLMultiArrayDataType data_type = MLMultiArrayDataTypeFloat32;
    if (input.data_type != ONNX_NAMESPACE::TensorProto_DataType_FLOAT) {
      NSLog(@"Input data type is not float, actual type: %i", input.data_type);
      return nil;
    }

    NSError* error = nil;
    MLMultiArray* mlArray = [[MLMultiArray alloc] initWithDataPointer:input.buffer
                                                                shape:shape
                                                             dataType:data_type
                                                              strides:strides
                                                          deallocator:(^(void* /* bytes */){
                                                                      })error:&error];
    if (error != nil) {
      NSLog(@"Failed to create MLMultiArray for feature %@ error: %@", featureName,
            [error localizedDescription]);
      return nil;
    }

    auto* mlFeatureValue = [MLFeatureValue featureValueWithMultiArray:mlArray];
    return mlFeatureValue;
  }

  return nil;
}

@end

@implementation CoreMLExecution

- (instancetype)initWithPath:(const std::string&)path {
  self = [super init];
  coreml_model_path_ = [NSString stringWithUTF8String:path.c_str()];
  return self;
}

- (void)cleanup {
  if (compiled_model_path_ != nil) {
    NSError* error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:compiled_model_path_ error:&error];
    if (error != nil) {
      NSLog(@"Failed cleaning up compiled model: %@", [error localizedDescription]);
    }
  }
}

- (void)dealloc {
  [self cleanup];
}

- (onnxruntime::common::Status)loadModel {
  NSError* error = nil;
  NSURL* modelUrl = [NSURL URLWithString:coreml_model_path_];
  NSURL* compileUrl = [MLModel compileModelAtURL:modelUrl error:&error];

  if (error != nil) {
    return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Error compiling model",
                           [[error localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
  }

  compiled_model_path_ = [compileUrl path];

  MLModelConfiguration* config = [MLModelConfiguration alloc];
  config.computeUnits = MLComputeUnitsAll;
  _model = [MLModel modelWithContentsOfURL:compileUrl configuration:config error:&error];

  if (error != NULL) {
    return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Error Creating MLModel",
                           [[error localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
  }

  return onnxruntime::common::Status::OK();
}

- (onnxruntime::common::Status)
    predict:(const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>&)inputs
    outputs:(const std::unordered_map<std::string, onnxruntime::coreml::OnnxTensorData>&)outputs {
  if (_model == nil) {
    return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "model is not loaded");
  }

  OnnxTensorFeatureProvider* input_feature = [[OnnxTensorFeatureProvider alloc] initWithInputs:inputs];

  if (input_feature == nil) {
    return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "inputFeature is not initialized");
  }

  MLPredictionOptions* options = [[MLPredictionOptions alloc] init];
  // TODO add options
  // options.usesCPUOnly = YES;
  NSError* error = nil;
  id<MLFeatureProvider> output_feature = [_model predictionFromFeatures:input_feature
                                                                options:options
                                                                  error:&error];

  if (error != nil) {
    return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Error executing model: ",
                           [[error localizedDescription] cStringUsingEncoding:NSUTF8StringEncoding]);
  }

  //   NSSet<NSString*>* output_feature_names = [output_feature featureNames];
  for (auto& output : outputs) {
    NSString* output_name = [NSString stringWithCString:output.first.c_str()
                                               encoding:[NSString defaultCStringEncoding]];
    MLFeatureValue* output_value =
        [output_feature featureValueForName:output_name];

    auto* data = [output_value multiArrayValue];
    auto* model_output_data = data.dataPointer;
    if (model_output_data == nullptr) {
      return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "model_output_data for ",
                             [output_name cStringUsingEncoding:NSUTF8StringEncoding],
                             " is null");
    }

    auto& output_tensor = output.second;
    size_t num_elements =
        accumulate(output_tensor.shape.begin(), output_tensor.shape.end(), 1, std::multiplies<int64_t>());

    if (output_tensor.data_type != ONNX_NAMESPACE::TensorProto_DataType_FLOAT) {
      return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL,
                             "Input data type is not float, actual type: ",
                             output_tensor.data_type);
    }

    // Delete
    NSLog(@"outputData[0] %f", ((float*)model_output_data)[5]);

    size_t output_data_byte_size = num_elements * sizeof(float);
    memcpy(output_tensor.buffer, model_output_data, output_data_byte_size);
  }

  return onnxruntime::common::Status::OK();
}

@end

namespace onnxruntime {
namespace coreml {

class Execution {
 public:
  Execution(const std::string& path);
  ~Execution(){};

  Status LoadModel();
  Status Predict(const std::unordered_map<std::string, OnnxTensorData>& inputs,
                 const std::unordered_map<std::string, OnnxTensorData>& outputs);

 private:
  bool model_loaded{false};
  CoreMLExecution* execution_;
};

Execution::Execution(const std::string& path) {
  execution_ = [[CoreMLExecution alloc] initWithPath:path];
}

Status Execution::LoadModel() {
  if (model_loaded)
    return Status::OK();
  if (HAS_VALID_OS_VERSION) {
    auto status = [execution_ loadModel];
    model_loaded = status.IsOK();
    return status;
  }

  return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Execution::LoadModel requires macos 10.15+ or ios 13+ ");
}

Status Execution::Predict(const std::unordered_map<std::string, OnnxTensorData>& inputs,
                          const std::unordered_map<std::string, OnnxTensorData>& outputs) {
  ORT_RETURN_IF_NOT(model_loaded, "Execution::Predict requires Execution::LoadModel");

  if (HAS_VALID_OS_VERSION) {
    return [execution_ predict:inputs outputs:outputs];
  }

  return ORT_MAKE_STATUS(ONNXRUNTIME, FAIL, "Execution::LoadModel requires macos 10.15+ or ios 13+ ");
}

Model::Model(const std::string& path)
    : execution_(onnxruntime::make_unique<Execution>(path)) {
}

Model::~Model() {}

Status Model::LoadModel() {
  return execution_->LoadModel();
}

Status Model::Predict(const std::unordered_map<std::string, OnnxTensorData>& inputs,
                      const std::unordered_map<std::string, OnnxTensorData>& outputs) {
  return execution_->Predict(inputs, outputs);
}

}  // namespace coreml
}  // namespace onnxruntime