def run(plan, args):
    env = args["env"]

    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))
    chainlink = import_module("github.com/LZeroAnalytics/chainlink-package@{}/main.star".format(env))
    uniswap = import_module("github.com/LZeroAnalytics/uniswap-package@{}/main.star".format(env))
    optimism = import_module("github.com/LZeroAnalytics/optimism-package@{}/main.star".format(env))
    graph = import_module("github.com/LZeroAnalytics/graph-package@{}/main.star".format(env))
    
    clean_args = {key: val for key, val in args.items() if key not in ("env", "optimism_params", "reset_state", "update_state")}
    ethereum_args = {key: val for key, val in clean_args.items() if key != "plugins"}

    # Retrieve running services
    services = plan.get_services()

    # Check whether to re-sync network
    reset_state = args.get("reset_state", False)
    if reset_state:
        for service in services:
            name = service.name
            # Remove all nodes
            if name.startswith("el-") or name.startswith("cl-") or name.startswith("vc-"):
                plan.remove_service(name=name)

    # Check whether to update block height
    update_state = args.get("update_state", False)
    if update_state:
        # Placeholder until we have get_service_config in Kurtosis
        forking_rpc_url = ethereum_args["participants"][0]["el_extra_env_vars"]["FORKING_RPC_URL"]
        block_height = ethereum_args["participants"][0]["el_extra_env_vars"]["FORKING_BLOCK_HEIGHT"]
        for service in services:
            if service.name.startswith("el-1"):
                service_config = ServiceConfig(env_vars={"FORKING_BLOCK_HEIGHT": block_height, "FORKING_RPC_URL": forking_rpc_url}, image="tiljordan/reth-forking:1.0.0", ports={"engine-rpc": PortSpec(number=8551, transport_protocol="TCP", application_protocol=""), "metrics": PortSpec(number=9001, transport_protocol="TCP", application_protocol="http"), "rpc": PortSpec(number=8545, transport_protocol="TCP", application_protocol=""), "tcp-discovery": PortSpec(number=30303, transport_protocol="TCP", application_protocol=""), "udp-discovery": PortSpec(number=30303, transport_protocol="UDP", application_protocol=""), "ws": PortSpec(number=8546, transport_protocol="TCP", application_protocol="")}, public_ports={}, files={"/jwt": "jwt_file", "/network-configs": "el_cl_genesis_data"}, cmd=["node", "-vvv", "--datadir=/data/reth/execution-data", "--chain=/network-configs/genesis.json", "--http", "--http.port=8545", "--http.addr=0.0.0.0", "--http.corsdomain=*", "--http.api=admin,net,eth,web3,debug,txpool,trace", "--rpc.gascap=500000000", "--ws", "--ws.addr=0.0.0.0", "--ws.port=8546", "--ws.api=net,eth", "--ws.origins=*", "--nat=extip:KURTOSIS_IP_ADDR_PLACEHOLDER", "--authrpc.port=8551", "--authrpc.jwtsecret=/jwt/jwtsecret", "--authrpc.addr=0.0.0.0", "--metrics=0.0.0.0:9001", "--discovery.port=30303", "--port=30303"], private_ip_address_placeholder="KURTOSIS_IP_ADDR_PLACEHOLDER", labels={"ethereum-package.client": "reth", "ethereum-package.client-image": "tiljordan-reth-forking_1-0-0", "ethereum-package.client-type": "execution", "ethereum-package.connected-client": "lighthouse", "ethereum-package.sha256": ""}, tolerations=[], node_selectors={})
                plan.add_service(name=service.name, config=service_config, description="Updating block height")
        return

    output = struct()

    def run_ethereum():
        plugins = args.get("plugins", {})
        if check_plugin_removal(plan, plugins, services):
            return struct(
                message="Plugin removed"
            )
        rpc_url = get_existing_rpc(plan,services)
        ethereum_output = rpc_url
        if not rpc_url:
            ethereum_output = ethereum.run(plan, ethereum_args)
            first = ethereum_output.all_participants[0]
            rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)

        result = struct()
        if plugins:
            if "chainlink" in plugins:
                network_type = plugins["chainlink"].get("network_type")
                chainlink_args = ethereum_args
                chainlink_args["network_type"] = network_type
                result = chainlink.run(plan, chainlink_args)
                first = result.all_participants[0]
                rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)
            if "graph" in plugins:
                if not is_service_running("graph-node", services):
                    network_type = plugins["graph"].get("network_type")
                    result = result + graph.run(plan, ethereum_args, network_type=network_type, rpc_url=rpc_url, env=env)
            if "uniswap" in plugins:
                if not is_service_running( "uniswap-backend", services):
                    backend_url = plugins["uniswap"].get("backend_url")
                    result = result + uniswap.run(plan, ethereum_args, rpc_url=rpc_url, backend_url=backend_url)
            return result

        return ethereum_output

    def wait_for_rpc_availability(plan, l1_config_env_vars):
        plan.run_sh(
            name="wait-for-rpc-availability",
            description="Wait for L1 RPC endpoint to respond with a valid chainId",
            env_vars=l1_config_env_vars,
            run='echo "Waiting for L1 RPC to respond..." ; \
                while true; do sleep 5; \
                echo "Pinging L1 RPC: $L1_RPC_URL"; \
                chain_id=$(curl -s -X POST -H "Content-Type: application/json" -d \'{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}\' $L1_RPC_URL | jq -r \'.result\'); \
                if [ "$chain_id" != "null" ] && [ ! -z "$chain_id" ]; then \
                echo "SUCCESS: RPC responded. Chain ID: $chain_id"; \
                break; \
                fi; \
                echo "RPC not ready yet, retrying..."; \
                done',
            wait="15m",
        )
        
    if "optimism_params" not in args:
        output = run_ethereum()
    else:
        if "external_l1_network_params" in args:
            external_l1_params = args["external_l1_network_params"]
            l1_config_env_vars = {
                "L1_RPC_URL": external_l1_params["el_rpc_url"]
            }

            wait_for_rpc_availability(plan, l1_config_env_vars)

            optimism_args = {
                "external_l1_network_params": external_l1_params,
                "optimism_package": args.get("optimism_params", {})
            }
            output = optimism.run(plan, optimism_args)

        else:
            # Run Ethereum (L1)
            l1_output = run_ethereum()

            # Run Optimism with L1 context
            external_l1_args = {
                "rpc_kind": "standard",
                "el_rpc_url": str(l1_output.all_participants[0].el_context.rpc_http_url),
                "cl_rpc_url": str(l1_output.all_participants[0].cl_context.beacon_http_url),
                "el_ws_url": str(l1_output.all_participants[0].el_context.ws_url),
                "network_id": str(l1_output.network_id),
                "priv_key": l1_output.pre_funded_accounts[12].private_key,
            }

            optimism_args = {
                "external_l1_network_params": external_l1_args,
                "optimism_package": args.get("optimism_params", {})
            }
            output = optimism.run(plan, optimism_args)

    return output


def check_plugin_removal(plan, plugins, services):
    # Check whether to remove Uniswap
    is_uniswap_running = is_service_running( "uniswap-backend", services)
    if (not plugins and is_uniswap_running) or (plugins and not "uniswap" in plugins and is_uniswap_running):
        plan.remove_service(name="uniswap-backend")
        plan.remove_service(name="uniswap-ui")
        return True

    is_graph_running = is_service_running("graph-node", services)
    if (not plugins and is_graph_running) or (plugins and not "graph" in plugins and is_graph_running):
        plan.remove_service(name="postgres")
        plan.remove_service(name="graph-node")
        plan.remove_service(name="ipfs")
        return True

    return False

def is_service_running(service_name, services):
    is_running = False
    for service in services:
        if service.name == service_name:
            is_running = True

    return is_running

def get_existing_rpc(plan, services):
    rpc_url = None
    for service in services:
        if "el-1" in service.name:
            ports = service.ports
            rpc_url = "http://{}:{}".format(service.ip_address, ports["rpc"].number)
            break
    return rpc_url