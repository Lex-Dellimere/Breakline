# nft_docker tests run real nftables in a throwaway container: mix test --only nft_docker
# deb_docker tests build the .deb and install it in one: mix test --only deb_docker
ExUnit.start(exclude: [:nft_docker, :deb_docker], assert_receive_timeout: 1000)
