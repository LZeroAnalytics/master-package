ethereum = import_module("github.com/LZeroAnalytics/ethereum-package/main.star")
chainlink = import_module("github.com/LZeroAnalytics/chainlink-package/main.star")
uniswap = import_module("github.com/LZeroAnalytics/uniswap-package/main.star")


def run(plan, args):
    output = struct()
    if "plugins" not in args:
        output = ethereum.run(plan, args)
        return output

    # Remove plugins key
    ethereum_args = {}
    for key in args:
        if key != "plugins":
            ethereum_args[key] = args[key]

    if "chainlink" in args["plugins"]:
        output = chainlink.run(plan, ethereum_args)
    else:
        output = ethereum.run(plan, ethereum_args)

    plan.print(output)
    if "uniswap" in args["plugins"]:
        rpc_url = "http://{}:{}".format(output.all_participants[0].el_context.ip_addr, output.all_participants[0].el_context.rpc_port_num)
        backend_url = args["uniswap_params"]["backend_url"]
        uniswap.run(
            plan,
            rpc_url=rpc_url,
            backend_url=backend_url
        )

    return output