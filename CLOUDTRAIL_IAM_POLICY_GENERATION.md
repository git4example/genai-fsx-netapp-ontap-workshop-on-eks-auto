# CloudTrail + IAM Access Analyzer — Temporary Setup for IAM Policy Generation

## Purpose

We temporarily added CloudTrail and IAM Access Analyzer resources to the workshop CloudFormation template so we can:

1. Deploy the workshop with `AdministratorAccess` on the VSCode instance role.
2. Run through the entire workshop flow (CloudTrail records every API call).
3. Use IAM Access Analyzer's **policy generation** feature to analyze the CloudTrail logs and produce a least-privilege IAM policy for the instance role.
4. Replace `AdministratorAccess` with the generated policy.

Once the least-privilege policy is extracted, all CloudTrail/Access Analyzer resources should be removed.

---

## Relevant Commits

| Commit | Description |
|--------|-------------|
| `0a1db67` | Reverted instance role to `AdministratorAccess` (temporary, to allow full test run) |
| `9bbfd84` | Added CloudTrail + Access Analyzer resources to CFN template |
| `f85ccb3` | Scoped down `PassRole` and `CreateServiceLinkedRole` based on Access Analyzer warnings |

---

## What Was Added to the CFN Template

**File:** `static/GenAIFSXWorkshopOnEKS.yaml`

### 1. Instance Role — Temporary AdministratorAccess (commit `0a1db67`)

The `VSCodeInstanceRole` managed policy list was replaced with a single entry:

```yaml
ManagedPolicyArns:
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AdministratorAccess
```

**Previous value** (to restore after policy generation):

```yaml
ManagedPolicyArns:
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonSSMManagedInstanceCore
  - !Sub arn:${AWS::Partition}:iam::aws:policy/CloudWatchAgentServerPolicy
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonQDeveloperAccess
  - !Sub arn:${AWS::Partition}:iam::aws:policy/ReadOnlyAccess
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonEKSClusterPolicy
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy
  - !Sub arn:${AWS::Partition}:iam::aws:policy/IAMFullAccess
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonVPCFullAccess
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonEC2FullAccess
  - !Sub arn:${AWS::Partition}:iam::aws:policy/AmazonEKS_CNI_Policy
```

### 2. S3 Bucket for CloudTrail Logs (commit `9bbfd84`, lines 216–225)

```yaml
PolicyGenCloudTrailBucket:
  Type: AWS::S3::Bucket
  DeletionPolicy: Delete
  Properties:
    BucketName: !Sub cloudtrail-policy-gen-${AWS::AccountId}
    LifecycleConfiguration:
      Rules:
        - Id: AutoDelete
          Status: Enabled
          ExpirationInDays: 7
```

### 3. S3 Bucket Policy for CloudTrail (commit `9bbfd84`, lines 227–248)

```yaml
PolicyGenCloudTrailBucketPolicy:
  Type: AWS::S3::BucketPolicy
  Properties:
    Bucket: !Ref PolicyGenCloudTrailBucket
    PolicyDocument:
      Version: 2012-10-17
      Statement:
        - Sid: AWSCloudTrailAclCheck
          Effect: Allow
          Principal:
            Service: cloudtrail.amazonaws.com
          Action: s3:GetBucketAcl
          Resource: !GetAtt PolicyGenCloudTrailBucket.Arn
          Condition:
            StringEquals:
              aws:SourceArn: !Sub arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${AWS::AccountId}:trail/workshop-policy-gen
        - Sid: AWSCloudTrailWrite
          Effect: Allow
          Principal:
            Service: cloudtrail.amazonaws.com
          Action: s3:PutObject
          Resource: !Sub ${PolicyGenCloudTrailBucket.Arn}/AWSLogs/${AWS::AccountId}/*
          Condition:
            StringEquals:
              aws:SourceArn: !Sub arn:${AWS::Partition}:cloudtrail:${AWS::Region}:${AWS::AccountId}:trail/workshop-policy-gen
```

### 4. CloudTrail Trail (commit `9bbfd84`, lines 250–258)

```yaml
PolicyGenCloudTrail:
  Type: AWS::CloudTrail::Trail
  DependsOn: PolicyGenCloudTrailBucketPolicy
  Properties:
    TrailName: workshop-policy-gen
    S3BucketName: !Ref PolicyGenCloudTrailBucket
    IsLogging: true
    IsMultiRegionTrail: true
    IncludeGlobalServiceEvents: true
    EnableLogFileValidation: true
```

### 5. IAM Role for Access Analyzer (commit `9bbfd84`, lines 261–283)

```yaml
AccessAnalyzerPolicyGenRole:
  Type: AWS::IAM::Role
  Properties:
    RoleName: AccessAnalyzerPolicyGen
    AssumeRolePolicyDocument:
      Version: 2012-10-17
      Statement:
        - Effect: Allow
          Principal:
            Service: access-analyzer.amazonaws.com
          Action: sts:AssumeRole
    Policies:
      - PolicyName: CloudTrailS3Access
        PolicyDocument:
          Version: 2012-10-17
          Statement:
            - Effect: Allow
              Action:
                - s3:GetObject
                - s3:ListBucket
              Resource:
                - !GetAtt PolicyGenCloudTrailBucket.Arn
                - !Sub ${PolicyGenCloudTrailBucket.Arn}/*
```

### 6. Stack Outputs (commit `9bbfd84`, lines 2441–2450)

```yaml
CloudTrailArn:
  Description: CloudTrail ARN for IAM Access Analyzer policy generation
  Value: !GetAtt PolicyGenCloudTrail.Arn
AccessAnalyzerRoleArn:
  Description: IAM role ARN for Access Analyzer to read CloudTrail S3 bucket
  Value: !GetAtt AccessAnalyzerPolicyGenRole.Arn
VSCodeInstanceRoleArn:
  Description: VSCode instance role ARN (target for policy generation)
  Value: !GetAtt VSCodeInstanceRole.Arn
```

---

## How to Use This Setup (Replication Guide)

### Step 1 — Deploy with AdministratorAccess

Set the instance/compute role to `AdministratorAccess` so every API call the workshop makes is allowed and recorded.

### Step 2 — Deploy the Stack

The CloudFormation stack creates the CloudTrail trail, S3 bucket, and Access Analyzer role automatically.

### Step 3 — Run the Full Workshop

Execute every step of the workshop end-to-end. CloudTrail will log all API calls made by the instance role.

### Step 4 — Generate Policy with Access Analyzer

Wait at least 1 hour after the test run, then use the AWS CLI:

```bash
# Get values from stack outputs
TRAIL_ARN=$(aws cloudformation describe-stacks \
  --stack-name <STACK_NAME> \
  --query "Stacks[0].Outputs[?OutputKey=='CloudTrailArn'].OutputValue" \
  --output text)

ANALYZER_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name <STACK_NAME> \
  --query "Stacks[0].Outputs[?OutputKey=='AccessAnalyzerRoleArn'].OutputValue" \
  --output text)

INSTANCE_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name <STACK_NAME> \
  --query "Stacks[0].Outputs[?OutputKey=='VSCodeInstanceRoleArn'].OutputValue" \
  --output text)

# Start policy generation (adjust dates to cover your test window)
aws accessanalyzer start-policy-generation \
  --policy-generation-details '{
    "principalArn": "'$INSTANCE_ROLE_ARN'"
  }' \
  --cloud-trail-details '{
    "trails": [{"cloudTrailArn": "'$TRAIL_ARN'", "allRegions": true}],
    "startTime": "2026-04-20T00:00:00Z",
    "endTime": "2026-04-21T00:00:00Z",
    "accessRole": "'$ANALYZER_ROLE_ARN'"
  }'

# Check status (takes a few minutes)
JOB_ID=<job-id-from-above>
aws accessanalyzer get-generated-policy --job-id $JOB_ID
```

### Step 5 — Review and Apply the Generated Policy

The output gives you a least-privilege policy. Review it, then replace `AdministratorAccess` on the instance role.

---

## Removal Checklist

When you're ready to remove the temporary CloudTrail setup:

### In `static/GenAIFSXWorkshopOnEKS.yaml`:

1. **Delete these Resources** (lines 215–283 in current file):
   - `PolicyGenCloudTrailBucket` (S3 bucket)
   - `PolicyGenCloudTrailBucketPolicy` (S3 bucket policy)
   - `PolicyGenCloudTrail` (CloudTrail trail)
   - `AccessAnalyzerPolicyGenRole` (IAM role)
   - The comment line `### CloudTrail for IAM Access Analyzer Policy Generation`

2. **Delete these Outputs** (lines 2441–2450 in current file):
   - `CloudTrailArn`
   - `AccessAnalyzerRoleArn`
   - `VSCodeInstanceRoleArn`

3. **Replace `AdministratorAccess`** on `VSCodeInstanceRole` (line 1050) with the generated least-privilege policy or the scoped-down managed policy list.

### Clean up deployed resources (if stack is live):

```bash
# Empty the CloudTrail S3 bucket first (required before stack deletion)
aws s3 rm s3://cloudtrail-policy-gen-<ACCOUNT_ID> --recursive

# Then delete/update the stack
```
