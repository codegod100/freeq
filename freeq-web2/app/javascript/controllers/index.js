import { application } from "./application";
import ChatController from "./chat_controller";
import CallController from "./call_controller";

application.register("chat", ChatController);
application.register("call", CallController);