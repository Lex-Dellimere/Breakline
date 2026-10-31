# nft_docker tests run real nftables in a throwaway container: mix test --only nft_docker
ExUnit.start(exclude: [:nft_docker], assert_receive_timeout: 1000)
