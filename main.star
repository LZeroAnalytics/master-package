def run(plan, args):
    env = args["env"]

    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))
    chainlink = import_module("github.com/LZeroAnalytics/chainlink-package@{}/main.star".format(env))
    uniswap = import_module("github.com/LZeroAnalytics/uniswap-package@{}/main.star".format(env))
    optimism = import_module("github.com/LZeroAnalytics/optimism-package@{}/main.star".format(env))
    graph = import_module("github.com/LZeroAnalytics/graph-package@{}/main.star".format(env))
    
    clean_args = {key: val for key, val in args.items() if key not in ("env", "optimism_params")}
    ethereum_args = {key: val for key, val in clean_args.items() if key != "plugins"}

    # Retrieve running services
    services = plan.get_services()

    output = struct()

    def run_ethereum():
        plugins = args.get("plugins", {})
        if check_plugin_removal(plan, plugins, services):
            return struct(
                message="Plugin removed"
            )
        rpc_url = get_existing_rpc(plan)
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
                    result = result + graph.run(plan, ethereum_args, rpc_url=rpc_url, env=env)
            if "uniswap" in plugins:
                if not is_service_running( "uniswap-backend", services):
                    backend_url = plugins["uniswap"].get("backend_url")
                    result = result + uniswap.run(plan, ethereum_args, rpc_url=rpc_url, backend_url=backend_url)
            return result

        return ethereum_output

    if "optimism_params" not in args:
        output = run_ethereum()

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

def get_existing_rpc(plan):
    services = plan.get_services()
    rpc_url = None
    for service in services:
        if "el-1" in service.name:
            ports = service.ports
            rpc_url = "http://{}:{}".format(service.ip_address, ports["rpc"].number)
            break
    return rpc_url