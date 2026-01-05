ENV=dev

init:
	@echo '## Initializing...'
	terraform -chdir=./aks-foundation init -upgrade
	@if [[ ($(ENV)=dev) || ($(ENV)=prd) ]]; then \
		echo '\n## Workspace selecting...'; \
		terraform -chdir=./aks-foundation workspace select $(ENV) || terraform -chdir=./aks-foundation workspace new $(ENV); \
		echo '\n selected: $(ENV)'; \
	else \
		echo 'Invalid value (production run: make init ENV=prd )'; \
		exit 1; \
	fi

plan: init
	@echo '## Planning...'
	terraform -chdir=./aks-foundation plan -out=tfplan

apply: plan
	@echo '## Applying...'
	@terraform show 'tfplan' >/dev/null 2>&1 || make plan
	terraform -chdir=./aks-foundation apply 'tfplan'
	rm ./aks-foundation/tfplan

destroy:
	@echo '## Destroying... TAKE CARE MAFREND!!!'
	terraform -chdir=./aks-foundation destroy -lock=false -auto-approve
	
upgrade: init plan apply

rm-tfplan:
	@echo '## Removing...'
	rm aks-foundation/tfplan

# environment-up:
# 	@echo '## Scaling up...'
# 	kubectl get ns  --no-headers -o custom-columns=":metadata.name" | grep -v kube | xargs -S 1024 -I {} sh -c 'kubectl annotate --overwrite namespace {} downscaler/force-; kubectl annotate --overwrite namespace {} downscaler/force-uptime="true"; kubectl label --overwrite namespace {} downscaler/manual="true"'
# 	kubectl scale --replicas=2 -n kube-system deployment coredns
# 	kubectl scale --replicas=2 -n kube-system deployment karpenter
# 	kubectl scale --replicas=2 -n kube-system deployment ebs-csi-controller

# environment-down:
# 	@echo '## Scaling down...'
# 	for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" | grep -v '^kube'); do echo "Processing $ns"; kubectl annotate --overwrite namespace $ns downscaler/force-uptime-; kubectl annotate --overwrite namespace $$ns downscaler/force-downtime-; kubectl label --overwrite namespace $$ns downscaler/manual-; done
# 	kubectl scale --replicas=1 -n kube-system deployment coredns
# 	kubectl scale --replicas=1 -n kube-system deployment karpenter
# 	kubectl scale --replicas=1 -n kube-system deployment ebs-csi-controller