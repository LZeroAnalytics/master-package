def run(plan, args):
    env = args["env"]

    ethereum = import_module("github.com/LZeroAnalytics/ethereum-package@{}/main.star".format(env))
    chainlink = import_module("github.com/LZeroAnalytics/chainlink-package@{}/main.star".format(env))
    uniswap = import_module("github.com/LZeroAnalytics/uniswap-package@{}/main.star".format(env))
    optimism = import_module("github.com/LZeroAnalytics/optimism-package@{}/main.star".format(env))
    
    clean_args = {key: val for key, val in args.items() if key not in ("env", "optimism_params")}
    ethereum_args = {key: val for key, val in clean_args.items() if key != "plugins"}

    output = struct()

    def run_ethereum():
        plugins = args.get("plugins", {})
        if plugins:
            rpc_url = None
            if "chainlink" in plugins:
                network_type = plugins["chainlink"].get("network_type")
                ethereum_args["network_type"] = network_type
                result = chainlink.run(plan, ethereum_args)
                first = result.all_participants[0]
                rpc_url = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num)
            if "uniswap" in plugins:
                backend_url = plugins["uniswap"].get("backend_url")
                return uniswap.run(plan, ethereum_args, rpc_url, backend_url)
        return ethereum.run(plan, ethereum_args)

    if "optimism_params" not in args:
        run_ethereum()

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