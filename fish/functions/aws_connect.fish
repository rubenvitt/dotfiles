alias _export_vault="export VAULT_ADDR=https://vault.dev.kauf.breuni.de; and vault login -method=ldap username=rvitt password=(op item get --vault Breuninger Breuninger --field password)"

function aws_connect
    set -l environment (gum choose "dev" "prod")
    set -l otp (op item get --vault Breuninger AWS --otp)

    if test "$environment" = "dev"
        gum style --foreground 2 --bold "Selected environment: dev"
        aws_get_session br-team-kauf-dev kauf_developer "$otp"
        _export_vault
        set -gx AWS_PROFILE breuninger-br-team-kauf-dev
        aws eks update-kubeconfig --name br-team-kauf-dev --region eu-central-1 --alias breuninger-br-team-kauf-dev
    else if test "$environment" = "prod"
        gum style --foreground 1 --bold "Selected environment: prod"
        aws_get_session br-team-kauf-prod kauf_developer "$otp"
        _export_vault
        set -gx AWS_PROFILE breuninger-br-team-kauf-prod
        aws eks update-kubeconfig --name br-team-kauf-prod --region eu-central-1 --alias breuninger-br-team-kauf-prod
    else
        gum style --foreground 1 --bold "Unknown environment: $environment - use 'dev' or 'prod'"
        return 1
    end
end
