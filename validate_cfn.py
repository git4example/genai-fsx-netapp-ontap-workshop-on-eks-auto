"""Validate CFN template structure, tolerating AWS intrinsics."""
import yaml


class CFNLoader(yaml.SafeLoader):
    pass


def cfn_tag_constructor(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node)


CFNLoader.add_multi_constructor("!", cfn_tag_constructor)

with open("static/GenAIFSXWorkshopOnEKS.yaml") as f:
    doc = yaml.load(f, Loader=CFNLoader)

print("=== Outputs ===")
for k in doc["Outputs"]:
    print(" -", k)

print("\n=== VSCodeInstanceRole policy ===")
role = doc["Resources"]["VSCodeInstanceRole"]["Properties"]
print("ManagedPolicyArns:", len(role["ManagedPolicyArns"]))
eks_stmt = next(s for s in role["Policies"][0]["PolicyDocument"]["Statement"]
                if s.get("Sid") == "EKSLifecycle")
print("eks:DescribeCluster in EKSLifecycle:", "eks:DescribeCluster" in eks_stmt["Action"])
