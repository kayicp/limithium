import { Actor, HttpAgent } from "@dfinity/agent";

export async function genActor(idlFactory, canisterId, identity = null) {
	const agent = await (!identity? HttpAgent.create() : HttpAgent.create({ identity }));
	if (process.env.DFX_NETWORK !== 'ic') await agent.fetchRootKey();
	return Actor.createActor(idlFactory, { agent, canisterId });
}