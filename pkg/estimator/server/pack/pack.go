/*
Copyright 2025 The Karmada Authors.

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

// Package pack provides bin packing algorithms for component set scheduling.
package pack

import (
	"sort"

	corev1 "k8s.io/api/core/v1"

	"k8s.io/component-helpers/scheduling/corev1/nodeaffinity"

	"github.com/karmada-io/karmada/pkg/estimator/pb"
	nodeutil "github.com/karmada-io/karmada/pkg/estimator/server/nodes"
	"github.com/karmada-io/karmada/pkg/util"
	"github.com/karmada-io/karmada/pkg/util/lifted/scheduler/framework"
)

type componentItem struct {
	resourceList corev1.ResourceList
	replicas     int32
	affinity     nodeaffinity.RequiredNodeAffinity
	tolerations  []corev1.Toleration
}

type NodeContainer struct {
	Node     *corev1.Node
	Resource *util.Resource
}

// calculates the maximum number of complete component sets that can be placed on the given node resources.
// This function uses a greedy algorithm to place components based on their resource requirements.
func CalculateMaxComponentSets(
	allNodes []*framework.NodeInfo,
	components []pb.ComponentRequirements,
) int32 {

	items := convertComponents(components)
	contains := convertContainers(allNodes)

	// greedy algorithm to place components
	placedSets := int32(0)
	for {
		// try to place one complete set of components
		if canPlaceOneSet(contains, items) {
			placedSets++
		} else {
			break
		}
	}

	return placedSets
}

func convertComponents(components []pb.ComponentRequirements) []componentItem {
	items := make([]componentItem, len(components))

	for i, comp := range components {
		items[i] = componentItem{
			resourceList: comp.ReplicaRequirements.ResourceRequest,
			replicas:     comp.Replicas,
		}
		items[i].affinity = nodeutil.GetRequiredNodeAffinity(comp.ReplicaRequirements)
		if comp.ReplicaRequirements.NodeClaim != nil {
			items[i].tolerations = comp.ReplicaRequirements.NodeClaim.Tolerations
		}
	}

	sort.Slice(items, func(i, j int) bool {
		return calculateWeight(items[i].resourceList) > calculateWeight(items[j].resourceList)
	})

	return items
}

func calculateWeight(rl corev1.ResourceList) int64 {
	var weight int64

	if cpu, ok := rl[corev1.ResourceCPU]; ok {
		weight += cpu.MilliValue()
	}
	if mem, ok := rl[corev1.ResourceMemory]; ok {
		weight += mem.Value()
	}

	return weight
}

func convertContainers(allNodes []*framework.NodeInfo) []NodeContainer {
	containers := make([]NodeContainer, 0, len(allNodes))

	for _, node := range allNodes {
		available := node.Allocatable.Clone().SubResource(node.Requested)
		available.AllowedPodNumber = util.MaxInt64(available.AllowedPodNumber-int64(len(node.Pods)), 0)

		if available.AllowedPodNumber <= 0 {
			continue
		}

		containers = append(containers, NodeContainer{
			Node:     node.Node(),
			Resource: available,
		})
	}

	return containers
}

func canPlaceOneSet(containers []NodeContainer, items []componentItem) bool {
	for i := range items {
		if !placeComponent(containers, &items[i]) {
			return false
		}
	}
	return true
}

func placeComponent(containers []NodeContainer, item *componentItem) bool {
	remainingReplicas := item.replicas

	for _, container := range containers {
		if remainingReplicas == 0 {
			break
		}

		if !nodeutil.IsNodeAffinityMatched(container.Node, item.affinity) || !nodeutil.IsTolerationMatched(container.Node, item.tolerations) {
			continue
		}

		maxReplicas := int32(container.Resource.MaxDivided(item.resourceList))
		canPlace := util.MinInt32(maxReplicas, remainingReplicas)

		if canPlace > 0 {
			for i := int32(0); i < canPlace; i++ {
				container.Resource.SubResource(util.NewResource(item.resourceList))
			}
			container.Resource.AllowedPodNumber -= int64(canPlace)
			remainingReplicas -= canPlace
		}
	}

	return remainingReplicas == 0
}
