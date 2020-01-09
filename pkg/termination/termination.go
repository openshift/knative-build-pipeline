/*
Copyright 2019 The Tekton Authors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package termination

import (
	"encoding/json"
	"io/ioutil"
	"os"

	v1alpha1 "github.com/tektoncd/pipeline/pkg/apis/pipeline/v1alpha1"
)

func WriteMessage(path string, pro []v1alpha1.PipelineResourceResult) error {
	// if the file at path exists, concatenate the new values otherwise create it
	// file at path already exists
	fileContents, err := ioutil.ReadFile(path)
	if err == nil {
		var existingEntries []v1alpha1.PipelineResourceResult
		if err := json.Unmarshal([]byte(fileContents), &existingEntries); err == nil {
			// append new entries to existing entries
			pro = append(existingEntries, pro...)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	jsonOutput, err := json.Marshal(pro)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0666)
	if err != nil {
		return err
	}
	defer f.Close()

	if _, err = f.Write(jsonOutput); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	return nil
}