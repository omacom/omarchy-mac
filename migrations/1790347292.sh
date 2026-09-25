echo "Hand the machine to its platform's migration onto the official packages, where there is one"

# A no-op wherever no boot package implements it. The resolve is an assignment
# so an undetermined platform fails the migration instead of skipping it.
entrypoint=$(omarchy-lifecycle-dispatch --resolve migrate)
if [[ -n $entrypoint ]]; then
  sudo omarchy-lifecycle-dispatch migrate
fi
