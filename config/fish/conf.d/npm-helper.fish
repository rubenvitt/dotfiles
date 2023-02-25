function npm
  if test -f yarn.lock
    echo 'Dies ist ein yarn Projekt. Bitte verwende yarn.';
  else if test -f pnpm-lock.yaml
    echo 'Dies ist ein pnpm Projekt. Bitte verwende pnpm.';
  else
    command npm $argv;
  end
end

function yarn
  if test -f package-lock.json
    echo 'Dies ist ein npm Projekt. Bitte verwende npm.';
  else if test -f pnpm-lock.yaml
    echo 'Dies ist ein pnpm Projekt. Bitte verwende pnpm.';
  else
    command yarn $argv;
  end
end

function pnpm
  if test -f package-lock.json
    echo 'Dies ist ein npm Projekt. Bitte verwende npm.';
  else if test -f yarn.lock
    echo 'Dies ist ein yarn Projekt. Bitte verwende yarn.';
  else
    command pnpm $argv;
  end
end
