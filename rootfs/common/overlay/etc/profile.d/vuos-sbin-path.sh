# Ensure /usr/sbin and /sbin are in PATH for interactive shells
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) PATH="$PATH:/usr/sbin" ;;
esac
case ":$PATH:" in
  *:/sbin:*) ;;
  *) PATH="$PATH:/sbin" ;;
esac
export PATH
