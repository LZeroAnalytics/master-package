def run(plan, args):
    env = args["env"]

    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))
    chainlink = import_module("github.com/LZeroAnalytics/chainlink-package@{}/main.star".format(env))
    uniswap = import_module("github.com/LZeroAnalytics/uniswap-package@{}/main.star".format(env))
    optimism = import_module("github.com/LZeroAnalytics/optimism-package@{}/main.star".format(env))
    graph = import_module("github.com/LZeroAnalytics/graph-package@{}/main.star".format(env))
    vrf = import_module("github.com/LZeroAnalytics/chainlink-vrf-package@{}/main.star".format(env))
    dfns = import_module("github.com/LZeroAnalytics/dfns-package@{}/main.star".format(env))

    clean_args = {key: val for key, val in args.items() if key not in ("optimism_params", "reset_state", "update_state", "update")}
    ethereum_args = {key: val for key, val in clean_args.items() if key != "plugins"}

    if "optimism_params" in args and "external_l1_network_params" in args:
        external_l1_params = args["external_l1_network_params"]
        l1_config_env_vars = {
            "L1_RPC_URL": external_l1_params["el_rpc_url"]
        }

        wait_for_rpc_availability(plan, l1_config_env_vars)

        optimism_args = {
            "external_l1_network_params": external_l1_params,
            "optimism_package": args.get("optimism_params", {})
        }
        return optimism.run(plan, optimism_args)

    running_services = plan.get_running_services()
    participants = ethereum_args["participants"]
    node_services = []
    counter = 1
    for participant in participants:
        # Build node service names based on participant settings
        el_type = participant.get("el_type", "geth")
        cl_type = participant.get("cl_type", "lighthouse")
        vc_type = participant.get("vc_type", "lighthouse")
        n = participant.get("count", 1)

        for _ in range(n):
            node_services.append("el-{}-{}-{}".format(counter, el_type, cl_type))
            node_services.append("cl-{}-{}-{}".format(counter, cl_type, el_type))
            node_services.append("vc-{}-{}-{}".format(counter, el_type, vc_type))
            counter += 1

    # Check whether to re-sync network
    reset_state = args.get("reset_state", False)
    if reset_state:
        for service_name in node_services:
            plan.remove_service(name=service_name)

    # Check whether to update block height
    update_state = args.get("update_state", False)
    if update_state:
        # Placeholder until we have get_service_config in Kurtosis
        forking_rpc_url = ethereum_args["participants"][0]["el_extra_env_vars"]["FORKING_RPC_URL"]
        block_height = ethereum_args["participants"][0]["el_extra_env_vars"]["FORKING_BLOCK_HEIGHT"]
        for service_name in node_services:
            if service_name.startswith("el"):
                service_config = ServiceConfig(env_vars={"FORKING_BLOCK_HEIGHT": block_height, "FORKING_RPC_URL": forking_rpc_url}, image="tiljordan/reth-forking:1.0.0", ports={"engine-rpc": PortSpec(number=8551, transport_protocol="TCP", application_protocol=""), "metrics": PortSpec(number=9001, transport_protocol="TCP", application_protocol="http"), "rpc": PortSpec(number=8545, transport_protocol="TCP", application_protocol=""), "tcp-discovery": PortSpec(number=30303, transport_protocol="TCP", application_protocol=""), "udp-discovery": PortSpec(number=30303, transport_protocol="UDP", application_protocol=""), "ws": PortSpec(number=8546, transport_protocol="TCP", application_protocol="")}, public_ports={}, files={"/jwt": "jwt_file", "/network-configs": "el_cl_genesis_data"}, cmd=["node", "-vvv", "--datadir=/data/reth/execution-data", "--chain=/network-configs/genesis.json", "--http", "--http.port=8545", "--http.addr=0.0.0.0", "--http.corsdomain=*", "--http.api=admin,net,eth,web3,debug,txpool,trace", "--rpc.gascap=500000000", "--ws", "--ws.addr=0.0.0.0", "--ws.port=8546", "--ws.api=net,eth", "--ws.origins=*", "--nat=extip:KURTOSIS_IP_ADDR_PLACEHOLDER", "--authrpc.port=8551", "--authrpc.jwtsecret=/jwt/jwtsecret", "--authrpc.addr=0.0.0.0", "--metrics=0.0.0.0:9001", "--discovery.port=30303", "--port=30303"], private_ip_address_placeholder="KURTOSIS_IP_ADDR_PLACEHOLDER", labels={"ethereum-package.client": "reth", "ethereum-package.client-image": "tiljordan-reth-forking_1-0-0", "ethereum-package.client-type": "execution", "ethereum-package.connected-client": "lighthouse", "ethereum-package.sha256": ""}, tolerations=[], node_selectors={})
                plan.add_service(name=service_name, config=service_config, description="Updating block height")
        return

    output = struct()

    def run_ethereum():
        plugins = args.get("plugins", {})

        check_plugin_removal(plan, plugins)

        if args.get("update", False):
            node_urls = get_existing_rpc_and_ws_url(plan, node_services)
            rpc_url = node_urls.rpc_url
            ws_url = node_urls.ws_url
            ethereum_output = rpc_url
        else:
            ethereum_output = ethereum.run(plan, ethereum_args)
            first = ethereum_output.all_participants[0]
            rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)
            ws_url = "ws://{}:{}".format(first.el_context.ip_addr, first.el_context.ws_port_num)

        result = struct()
        if plugins:
            if "chainlink" in plugins:
                network_type = plugins["chainlink"].get("network_type")
                chainlink_args = ethereum_args
                chainlink_args["network_type"] = network_type
                result = chainlink.run(plan, chainlink_args)
                first = result.all_participants[0]
                rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)
            if "graph" in plugins and not "graph-node" in running_services:
                network_type = plugins["graph"].get("network_type")
                result = result + graph.run(plan, ethereum_args, network_type=network_type, rpc_url=rpc_url, env=env)
            if "uniswap" in plugins and not "uniswap-backend" in running_services:
                backend_url = plugins["uniswap"].get("backend_url")
                result = result + uniswap.run(plan, ethereum_args, rpc_url=rpc_url, backend_url=backend_url)
            if "vrf" in plugins and not"chainlink-node-vrfv2plus-vrf" in running_services:
                vrf_args = setup_vrf_plugin_args(plan, plugins, rpc_url, ws_url)
                result = result + vrf.run(plan, vrf_args)
            if "dfns" in plugins and not "dfns-api" in running_services:
                dfns_plugin_args = plugins["dfns"]
                result = dfns.run(plan, rpc_url, dfns_plugin_args["chain_id"], dfns_plugin_args["network_type"], dfns_plugin_args["coingecko_api"], env)
            return result

        return ethereum_output

    run_ethereum()

    return output


def check_plugin_removal(plan, plugins):
    if "uniswap" not in plugins:
        plan.remove_service(name="uniswap-backend")
        plan.remove_service(name="uniswap-ui")

    if "graph" not in plugins:
        plan.remove_service(name="postgres")
        plan.remove_service(name="graph-node")
        plan.remove_service(name="ipfs")

    if "vrf" not in plugins:
        plan.remove_service(name="chainlink-node-vrfv2plus-vrf")
        plan.remove_service(name="chainlink-node-vrfv2plus-bhs")
        plan.remove_service(name="chainlink-node-vrfv2plus-bhf")
        plan.remove_service(name="chainlink-node-mpc-vrf-0")

    if "dfns" not in plugins:
        plan.remove_service(name="dfns-api")
        plan.remove_service(name="dfns-postgres")
        plan.remove_service(name="dfns-package-postgres")
        plan.remove_service(name="dfns-package-graph-node")
        plan.remove_service(name="dfns-package-ipfs")

def get_existing_rpc_and_ws_url(plan, services):
    rpc_url = None
    ws_url = None
    for service_name in services:
        if "el-1" in service_name:
            service = plan.get_service(service_name)
            ports = service.ports
            rpc_url = "http://{}:{}".format(service.ip_address, ports["rpc"].number)
            ws_url = "ws://{}:{}".format(service.ip_address, ports["ws"].number)
            break
    return struct(rpc_url=rpc_url, ws_url=ws_url)

def setup_vrf_plugin_args(plan, plugins, rpc_url, ws_url):
    vrf_plugin_args = plugins["vrf"]
    faucet = plan.get_service(name="faucet")
    vrf_args = {}
    
    vrf_args["network"] = {
        "type": vrf_plugin_args["network_type"],
        "rpc": rpc_url,
        "ws": ws_url,
        "chain_id": vrf_plugin_args.get("chain_id"),
        "private_key": vrf_plugin_args.get("private_key"),
        "faucet": "http://{}:{}".format(faucet.ip_address, faucet.ports["api"].number)
    }
    vrf_args["vrf"] = {
        "vrf_type": vrf_plugin_args.get("vrf_type"),
        "link_token_address": vrf_plugin_args.get("link_address"),
        "link_native_token_feed_address": vrf_plugin_args.get("link_native_token_feed_address")
    }
    return vrf_args

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