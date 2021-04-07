# Best practices for using Azure Cache for Redis with HiRedisCluster

## Improving Pipelining.

    Hireredis-cluster supports manually batching of requests to enhance pipelining.  Following is a sample code with pipelining of 4 requests.

### Code snippet to get started on HiRedisCluster with Azure.

       	redisClusterAppendCommand(conn, "SET %s %s", "test", "value");
		redisClusterAppendCommand(conn, "SET %s %s", "key", "value");
		redisClusterAppendCommand(conn, "GET %s", "test");
		redisClusterAppendCommand(conn, "GET %s", "key");
		for (size_t i = 0; i < 4; i++)
		{
		    redisClusterGetReply(conn,(void **) &reply[i]);
		    freeReplyObject(reply[i]);
        }
        redisClusterReset(conn);


## Leveraging Replica node for GET requests. 

### Following is a code sample that I have written to send writes to primary and reads to replica node. With synthetic benchmarking, I was able to get higher throughput by distributing the load across nodes of a shard.

            redisClusterSetOptionParseSlaves(cc[i]);
	        redisClusterConnect2(cc[i]);
	 
		    cluster_node *node1 = redisClusterGetNodeByKey(conn, "test");
		    cluster_node *replica1 = getReplica(node1);
		    
		    cluster_node *node2 = redisClusterGetNodeByKey(conn, "key");
		    cluster_node *replica2 = getReplica(node2);
		    redisClusterCommandToNode(conn, replica1, "READONLY");
		    redisClusterCommandToNode(conn, replica2, "READONLY");
		         redisReply *reply =
		            (redisReply *)redisClusterCommandToNode(conn, node1, "SET %s %s", "test1", "value");
		 
		        freeReplyObject(reply);
		        redisReply *reply1 =
		            (redisReply *)redisClusterCommandToNode(conn, node2, "SET %s %s", "test2", "value");
		        freeReplyObject(reply1);
		        
		        redisReply *reply2 = (redisReply *)redisClusterCommandToNode(conn, replica1, "GET %s", "test1");
		        freeReplyObject(reply2);
		        redisReply *reply3 = (redisReply *)redisClusterCommandToNode(conn, replica2, "GET %s", "test2");
            freeReplyObject(reply3);

        Note (not included in the sample above) when reading from replica node your client application needs to ensure to fallback to primary node in case replica isn't connected. 
		We recommend testing fallback to primary logic on a dev/stage cache by rebooting replica node. Similarly, we recommend testing reconnection logic during maintenance event on a dev/stage cache by rebooting the primary node.




### Full Code 

        #include "hircluster.h"
        #include <stdio.h>
        #include <stdlib.h>
        #include <pthread.h>
        #include <unistd.h>
        #include "adlist.h"


        redisClusterContext **cc;
        int numberOfConnections = 200;

        typedef struct threadarg
        {
            int connectionid;
        } threadarg;

        void *runLoad(void *arg)
        {
            int counter = *(int *)(arg);
            printf("using connection %d\n", counter);
            redisClusterContext *conn = cc[counter];
            while(1)
            {
                redisReply *reply =
                    (redisReply *)redisClusterCommand(conn, "SET %s %s", "test", "value");
                //printf("SET: %s\n", reply->str);
                freeReplyObject(reply);

                redisReply *reply1 =
                    (redisReply *)redisClusterCommand(conn, "SET %s %s", "key", "value");
                //printf("SET: %s\n", reply->str);
                freeReplyObject(reply1);

                redisReply *reply2 = (redisReply *)redisClusterCommand(conn, "GET %s", "test");
                //printf("GET: %s\n", reply2->str);
                freeReplyObject(reply2);

                redisReply *reply3 = (redisReply *)redisClusterCommand(conn, "GET %s", "key");
                //printf("GET: %s\n", reply2->str);
                freeReplyObject(reply3);
            }
            free(arg);
            return NULL;
        }


        void *runLoadWithPipeline(void *arg)
        {
            int counter = *(int *)(arg);
            printf("using connection %d\n", counter);
            redisClusterContext *conn = cc[counter];
            redisReply **reply;
            reply = malloc(sizeof(redisReply *) * 4);
            while(1)
            {
                redisClusterAppendCommand(conn, "SET %s %s", "test", "value");
                redisClusterAppendCommand(conn, "SET %s %s", "key", "value");
                redisClusterAppendCommand(conn, "GET %s", "test");
                redisClusterAppendCommand(conn, "GET %s", "key");
                for (size_t i = 0; i < 4; i++)
                {
                    redisClusterGetReply(conn,(void **) &reply[i]);
                    freeReplyObject(reply[i]);
                }
                redisClusterReset(conn);
            }
            free(reply);
            free(arg);
            return NULL;
        }

        cluster_node *getReplica(cluster_node *node)
        {
            cluster_node *replica = node;
            if (node->slaves && listLength(node->slaves) > 0)
            {
                printf("Using Replica\n");
                // get the first replica
                listIter li;
                listNode *ln;
                listRewind(node->slaves, &li);
                ln = listNext(&li);
                replica = listNodeValue(ln);
            }
            return replica;
        }

        void *runLoadWithReadFromReplicaPipeline(void *arg)
        {
            int counter = *(int *)(arg);
            printf("using connection %d\n", counter);
            redisClusterContext *conn = cc[counter];
            redisReply **reply;
            reply = malloc(sizeof(redisReply *) * 2);
            cluster_node *node1 = redisClusterGetNodeByKey(conn, "test");
            cluster_node *replica1 = getReplica(node1);
    
            cluster_node *node2 = redisClusterGetNodeByKey(conn, "key");
            cluster_node *replica2 = getReplica(node2);

            redisClusterCommandToNode(conn, replica1, "READONLY");
            redisClusterCommandToNode(conn, replica2, "READONLY");

            while(1)
            {
                 redisReply *reply =
                    (redisReply *)redisClusterCommandToNode(conn, node1, "SET %s %s", "test1", "value");
                //printf("SET: %s\n", reply->str);
                freeReplyObject(reply);

                redisReply *reply1 =
                    (redisReply *)redisClusterCommandToNode(conn, node2, "SET %s %s", "test2", "value");
                //printf("SET: %s\n", reply->str);
                freeReplyObject(reply1);
        
                redisReply *reply2 = (redisReply *)redisClusterCommandToNode(conn, replica1, "GET %s", "test1");
                //printf("GET: %s\n", reply2->str);
                freeReplyObject(reply2);

                redisReply *reply3 = (redisReply *)redisClusterCommandToNode(conn, replica2, "GET %s", "test2");
                //printf("GET: %s\n", reply2->str);
                freeReplyObject(reply3);
            }
            free(reply);
            free(arg);
            return NULL;
        }


        int main(int argc, char **argv) {
            UNUSED(argc);
            UNUSED(argv);
            struct timeval timeout = {1, 500000}; // 1.5s


            printf("Creating %d connections\n", numberOfConnections);
            cc = malloc(sizeof(redisClusterContext*) * numberOfConnections);
            for (size_t i = 0; i < numberOfConnections; i++)
            {
                cc[i] = redisClusterContextInit();
                redisClusterSetOptionAddNodes(cc[i], "<cluster>.redis.cache.windows.net:6379");
                redisClusterSetOptionConnectTimeout(cc[i], timeout);
                redisClusterSetOptionRouteUseSlots(cc[i]);
                redisClusterSetOptionPassword(cc[i],"<auth>");
                redisClusterSetOptionParseSlaves(cc[i]);
                redisClusterConnect2(cc[i]);
                if (cc[i] && cc[i]->err) {
                    printf("Error: %s\n", cc[i]->errstr);
                    exit(-1);
                }
            }
    
            printf("Completed creating %d connections\n", numberOfConnections);
            printf("Starting load on %d threads\n", numberOfConnections);
            pthread_t *thread_id; 
            thread_id = malloc(sizeof(pthread_t *) * numberOfConnections);
            for (size_t i = 0; i < numberOfConnections; i++)
            {
                int *connectionid= malloc(sizeof(int));
                *connectionid = i;
                // pthread_create(&thread_id[i], NULL, runLoad, connectionid); 
                pthread_create(&thread_id[i], NULL, runLoadWithPipeline, connectionid); 
                // pthread_create(&thread_id[i], NULL, runLoadWithReadFromReplicaPipeline, connectionid); 
                //pthread_create(&thread_id[i], NULL, runLoadWithReadFromReplicaPipeline, connectionid); 
            }
            printf("Waiting for load to complete \n");
            for (size_t i = 0; i < numberOfConnections; i++)
            {
                pthread_join(thread_id[i], NULL); 
            }

            printf("Load Completed\n");

            for (size_t i = 0; i < numberOfConnections; i++)
            {
                redisClusterFree(cc[i]);
            }
            return 0;
        }
